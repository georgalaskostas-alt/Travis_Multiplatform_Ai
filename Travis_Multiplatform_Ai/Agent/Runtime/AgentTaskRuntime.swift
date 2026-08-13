import Foundation
import Observation

/// Runtime v1 state machine for long-lived autonomous tasks.
///
/// Persistence and remote workers are intentionally injected later. This layer
/// defines deterministic task lifecycle semantics first: create, plan, start,
/// checkpoint, pause/resume, retry/fail, and complete.
@MainActor
@Observable
final class AgentTaskRuntime {
    private(set) var tasks: [AgentTask] = []

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
        return task
    }

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    func replacePlan(taskId: UUID, summary: String, steps: [PlanStep]) {
        mutate(taskId) { task in
            task.plan = TaskPlan(
                version: task.plan.version + (task.plan.steps.isEmpty ? 0 : 1),
                summary: summary,
                steps: steps
            )
            task.status = .pending
            task.events.append(TaskEvent(type: task.plan.version == 1 ? .planned : .replanned,
                                         message: summary))
        }
    }

    func start(taskId: UUID) {
        mutate(taskId) { task in
            guard ![.completed, .cancelled].contains(task.status) else { return }
            if task.startedAt == nil {
                task.startedAt = Date()
            }
            task.status = .running
            task.executionState.lastHeartbeatAt = Date()
            task.events.append(TaskEvent(type: .started, message: "Task execution started"))
        }
    }

    func pause(taskId: UUID, reason: String = "Paused") {
        mutate(taskId) { task in
            guard task.status == .running || task.status == .waitingForDependency else { return }
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
            task.events.append(TaskEvent(type: .cancelled, message: reason))
        }
    }

    func nextRunnableStep(taskId: UUID) -> PlanStep? {
        guard let task = task(id: taskId) else { return nil }

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
            guard let index = task.plan.steps.firstIndex(where: { $0.id == stepId }) else { return }
            task.status = .running
            task.executionState.currentStepId = stepId
            task.executionState.lastHeartbeatAt = Date()
            task.plan.steps[index].status = .running
            task.plan.steps[index].attemptCount += 1
            task.plan.steps[index].startedAt = task.plan.steps[index].startedAt ?? Date()
            task.events.append(TaskEvent(type: .progress,
                                         message: "Started step \(task.plan.steps[index].order): \(task.plan.steps[index].title)"))
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

            let unfinished = task.plan.steps.contains {
                ![.completed, .skipped, .cancelled].contains($0.status)
            }
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

            let maxAttempts = min(task.plan.steps[index].maxAttempts, task.budget.maxRetriesPerStep)
            if task.plan.steps[index].attemptCount < maxAttempts {
                task.plan.steps[index].status = .pending
                task.events.append(TaskEvent(type: .retry,
                                             message: "Step will retry: \(task.plan.steps[index].title) — \(error)"))
            } else {
                task.plan.steps[index].status = .failed
                task.status = .failed
                task.failureReason = error
                task.completedAt = Date()
                task.events.append(TaskEvent(type: .failed,
                                             message: "Step exhausted retries: \(task.plan.steps[index].title) — \(error)"))
            }
        }
    }

    func checkpoint(
        taskId: UUID,
        summary: String,
        nextAction: String? = nil
    ) {
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

    private func mutate(_ taskId: UUID, _ body: (inout AgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        body(&tasks[index])
        tasks[index].updatedAt = Date()
    }
}
