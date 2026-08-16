import Foundation
import Observation

/// Deterministic state machine for long-lived autonomous tasks.
/// Every state mutation is durably snapshotted so plans, checkpoints,
/// attempts and lifecycle state survive app/process recreation.
@MainActor
@Observable
final class AgentTaskRuntime {
    private(set) var tasks: [AgentTask] = []

    private let store: AgentTaskStore
    private(set) var persistenceError: String?

    init(store: AgentTaskStore = .shared) {
        self.store = store
        restorePersistedTasks()
    }

    @discardableResult
    func createTask(
        goal: String,
        title: String? = nil,
        priority: AgentTaskPriority = .medium,
        dueDate: Date? = nil,
        budget: TaskExecutionBudget = TaskExecutionBudget()
    ) -> AgentTask {
        var task = AgentTask(
            goal: goal,
            title: title,
            priority: priority,
            dueDate: dueDate,
            budget: budget
        )
        task.events.append(TaskEvent(type: .created, message: "Task created"))
        tasks.append(task)
        persist()
        return task
    }

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    /// Scheduler-facing deterministic view of tasks that can execute now.
    ///
    /// Ordering is stable and policy-free:
    /// 1. priority (critical → low)
    /// 2. earliest due date
    /// 3. oldest update time (prevents starvation among equal peers)
    /// 4. UUID as a final deterministic tie-breaker
    ///
    /// The scheduler may ask for background-only work so foreground-only
    /// steps never run merely because a worker became available.
    func dispatchableTasks(
        backgroundOnly: Bool = false,
        limit: Int = 8,
        now: Date = Date()
    ) -> [AgentTask] {
        let boundedLimit = max(1, min(limit, 64))

        return tasks
            .filter { task in
                guard task.status == .running else { return false }
                if let nextEligible = task.executionState.nextEligibleRunAt,
                   nextEligible > now {
                    return false
                }

                guard let step = nextRunnableStep(taskId: task.id, now: now) else {
                    return false
                }

                if backgroundOnly && !step.canRunInBackground {
                    return false
                }

                return true
            }
            .sorted(by: schedulerPrecedes)
            .prefix(boundedLimit)
            .map { $0 }
    }

    /// Read-only stale-task detection for a future worker/supervisor.
    /// It deliberately does not mutate state because a long-running capability
    /// may still be legitimately active; the supervisor decides whether to
    /// cancel, pause, probe, or wait.
    func staleRunningTasks(
        heartbeatOlderThan interval: TimeInterval,
        now: Date = Date()
    ) -> [AgentTask] {
        let threshold = now.addingTimeInterval(-max(1, interval))
        return tasks
            .filter { task in
                guard task.status == .running else { return false }
                guard let heartbeat = task.executionState.lastHeartbeatAt else { return true }
                return heartbeat < threshold
            }
            .sorted(by: schedulerPrecedes)
    }

    func attachPlan(taskId: UUID, plan: TaskPlan) {
        mutate(taskId) { task in
            task.plan = plan
            task.status = .pending
            task.failureReason = nil
            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0
            task.events.append(TaskEvent(type: .planned, message: "Plan attached: \(plan.summary)"))
        }
    }

    func replacePlan(taskId: UUID, summary: String, steps: [PlanStep]) {
        mutate(taskId) { task in
            let nextVersion = task.plan.steps.isEmpty ? 1 : task.plan.version + 1
            task.plan = TaskPlan(version: nextVersion, summary: summary, steps: steps)
            task.status = .pending
            task.failureReason = nil
            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0
            if nextVersion > 1 { task.executionState.replanCount += 1 }
            task.events.append(TaskEvent(type: nextVersion == 1 ? .planned : .replanned, message: summary))
        }
    }

    func start(taskId: UUID) {
        mutate(taskId) { task in
            guard ![.completed, .cancelled].contains(task.status) else { return }
            guard !task.plan.steps.isEmpty else {
                task.status = .failed
                task.failureReason = "Cannot start task without an execution plan."
                task.events.append(TaskEvent(type: .failed, message: "Task cannot start because no execution plan exists."))
                return
            }
            if task.startedAt == nil { task.startedAt = Date() }
            task.status = .running
            task.executionState.lastHeartbeatAt = Date()
            task.events.append(TaskEvent(type: .started, message: "Task execution started"))
        }
    }

    /// Pauses execution at a safe resumable boundary. If cancellation arrives
    /// while a step is in-flight, that step is returned to `.pending` rather
    /// than being counted as a failure/retry. No unverified result is accepted.
    func pause(taskId: UUID, reason: String = "Paused") {
        mutate(taskId) { task in
            guard [.running, .waitingForDependency, .waitingForApproval].contains(task.status) else { return }

            if let stepId = task.executionState.currentStepId,
               let index = task.plan.steps.firstIndex(where: { $0.id == stepId }),
               task.plan.steps[index].status == .running {
                task.plan.steps[index].status = .pending
                task.plan.steps[index].lastError = reason
            }

            task.executionState.currentStepId = nil
            task.executionState.nextEligibleRunAt = nil
            task.executionState.lastHeartbeatAt = Date()
            task.status = .paused
            task.events.append(TaskEvent(type: .paused, message: reason))
        }
    }

    func resume(taskId: UUID) {
        mutate(taskId) { task in
            guard task.status == .paused else { return }
            task.status = .running
            task.executionState.lastHeartbeatAt = Date()
            task.events.append(TaskEvent(type: .resumed, message: "Task resumed"))
        }
    }

    func cancel(taskId: UUID, reason: String = "Cancelled by user") {
        mutate(taskId) { task in
            guard ![.completed, .cancelled].contains(task.status) else { return }
            task.status = .cancelled
            task.completedAt = Date()
            task.executionState.currentStepId = nil
            task.events.append(TaskEvent(type: .cancelled, message: reason))
        }
    }

    func nextRunnableStep(taskId: UUID) -> PlanStep? {
        nextRunnableStep(taskId: taskId, now: Date())
    }

    private func nextRunnableStep(taskId: UUID, now: Date) -> PlanStep? {
        guard let task = task(id: taskId), task.status == .running else { return nil }
        if let next = task.executionState.nextEligibleRunAt, next > now { return nil }

        let completed = Set(task.plan.steps.filter { $0.status == .completed }.map(\.id))
        return task.plan.steps
            .sorted { $0.order < $1.order }
            .first { step in
                guard step.status == .pending || step.status == .ready else { return false }
                return step.dependencyStepIds.allSatisfy { completed.contains($0) }
            }
    }

    func markStepRunning(taskId: UUID, stepId: UUID) {
        mutate(taskId) { task in
            guard task.status == .running,
                  let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            let step = task.plan.steps[index]
            guard step.status == .pending || step.status == .ready else { return }

            task.executionState.currentStepId = stepId
            task.executionState.lastHeartbeatAt = Date()
            task.plan.steps[index].status = .running
            task.plan.steps[index].attemptCount += 1
            if task.plan.steps[index].startedAt == nil { task.plan.steps[index].startedAt = Date() }
            task.events.append(TaskEvent(type: .progress, message: "Started step \(step.order): \(step.title)"))
        }
    }

    func markStepCompleted(taskId: UUID, stepId: UUID, resultSummary: String? = nil) {
        mutate(taskId) { task in
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            task.plan.steps[index].status = .completed
            task.plan.steps[index].completedAt = Date()
            task.plan.steps[index].resultSummary = resultSummary
            task.plan.steps[index].lastError = nil
            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0
            task.executionState.lastHeartbeatAt = Date()
            task.executionState.nextEligibleRunAt = nil
            task.events.append(TaskEvent(type: .progress, message: "Completed step \(task.plan.steps[index].order): \(task.plan.steps[index].title)"))

            let unfinished = task.plan.steps.contains { ![.completed, .skipped, .cancelled].contains($0.status) }
            if unfinished {
                task.status = .running
            } else {
                task.status = .completed
                task.completedAt = Date()
                task.events.append(TaskEvent(type: .completed, message: "All plan steps completed"))
            }
        }
    }

    func markStepFailed(taskId: UUID, stepId: UUID, error: String) {
        mutate(taskId) { task in
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            task.plan.steps[index].lastError = error
            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures += 1
            task.executionState.lastHeartbeatAt = Date()

            let allowedAttempts = min(task.plan.steps[index].maxAttempts, task.budget.maxRetriesPerStep)
            if task.plan.steps[index].attemptCount < allowedAttempts {
                task.plan.steps[index].status = .pending
                task.events.append(TaskEvent(type: .retry, message: "Step will retry: \(task.plan.steps[index].title) — \(error)"))
            } else {
                task.plan.steps[index].status = .failed
                task.status = .failed
                task.failureReason = error
                task.completedAt = Date()
                task.events.append(TaskEvent(type: .failed, message: "Step exhausted retries: \(task.plan.steps[index].title) — \(error)"))
            }
        }
    }

    func markStepWaitingForApproval(taskId: UUID, stepId: UUID) {
        mutate(taskId) { task in
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            task.plan.steps[index].status = .waitingForApproval
            task.status = .waitingForApproval
            task.executionState.currentStepId = stepId
            task.events.append(TaskEvent(type: .approvalRequested, message: "Approval required for step \(task.plan.steps[index].order): \(task.plan.steps[index].title)"))
        }
    }

    func markStepApprovalGranted(taskId: UUID, stepId: UUID) {
        mutate(taskId) { task in
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }),
                  task.plan.steps[index].status == .waitingForApproval else { return }

            task.plan.steps[index].requiresApproval = false
            task.plan.steps[index].status = .ready
            task.status = .running
            task.executionState.currentStepId = nil
            task.executionState.lastHeartbeatAt = Date()
            task.events.append(TaskEvent(type: .approvalGranted, message: "Approval granted for step \(task.plan.steps[index].order)"))
        }
    }

    func markStepApprovalRejected(taskId: UUID, stepId: UUID, reason: String = "Approval rejected") {
        mutate(taskId) { task in
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            task.plan.steps[index].status = .cancelled
            task.status = .paused
            task.executionState.currentStepId = nil
            task.events.append(TaskEvent(type: .approvalRejected, message: reason))
        }
    }

    func checkpoint(taskId: UUID, summary: String, nextAction: String? = nil) {
        mutate(taskId) { task in
            let checkpoint = TaskCheckpoint(
                taskId: task.id,
                stepId: task.executionState.currentStepId,
                summary: summary,
                nextAction: nextAction
            )
            task.executionState.lastCheckpoint = checkpoint
            task.executionState.lastHeartbeatAt = Date()
            task.events.append(TaskEvent(type: .checkpoint, message: summary))
        }
    }

    func heartbeat(taskId: UUID, nextEligibleRunAt: Date? = nil) {
        mutate(taskId) { task in
            task.executionState.lastHeartbeatAt = Date()
            task.executionState.nextEligibleRunAt = nextEligibleRunAt
        }
    }

    func progress(taskId: UUID) -> Double {
        guard let task = task(id: taskId), !task.plan.steps.isEmpty else { return 0 }
        let completed = task.plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
        return Double(completed) / Double(task.plan.steps.count)
    }

    func reloadFromDisk() {
        restorePersistedTasks()
    }

    private func schedulerPrecedes(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        let lhsPriority = priorityRank(lhs.priority)
        let rhsPriority = priorityRank(rhs.priority)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }

        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func priorityRank(_ priority: AgentTaskPriority) -> Int {
        switch priority {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    private func mutate(_ taskId: UUID, _ body: (inout AgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        body(&tasks[index])
        tasks[index].updatedAt = Date()
        tasks[index].plan.updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try store.save(tasks)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            print("TRAVIS runtime persistence failed: \(error.localizedDescription)")
        }
    }

    private func restorePersistedTasks() {
        do {
            var restored = try store.load()

            for taskIndex in restored.indices {
                guard restored[taskIndex].status == .running else { continue }

                if let stepId = restored[taskIndex].executionState.currentStepId,
                   let stepIndex = restored[taskIndex].plan.steps.firstIndex(where: { $0.id == stepId }),
                   restored[taskIndex].plan.steps[stepIndex].status == .running {
                    restored[taskIndex].plan.steps[stepIndex].status = .pending
                    restored[taskIndex].plan.steps[stepIndex].lastError = "Recovered after process interruption before verified completion."
                }

                restored[taskIndex].executionState.currentStepId = nil
                restored[taskIndex].status = .paused
                restored[taskIndex].events.append(TaskEvent(
                    type: .paused,
                    message: "Recovered from durable snapshot after process interruption"
                ))
                restored[taskIndex].updatedAt = Date()
            }

            tasks = restored
            persistenceError = nil

            if !restored.isEmpty { persist() }
        } catch {
            tasks = []
            persistenceError = error.localizedDescription
            print("TRAVIS runtime recovery failed: \(error.localizedDescription)")
        }
    }
}
