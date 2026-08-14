import Foundation
import Observation

/// Runtime v1 state machine for long-lived autonomous tasks.
///
/// Persistence and remote workers are intentionally injected later.
/// This layer defines deterministic task lifecycle semantics first:
///
/// - create
/// - attach / replace plan
/// - start
/// - pause / resume
/// - checkpoint
/// - step execution state
/// - retry / fail
/// - complete
///
/// The runtime itself does NOT execute capabilities yet.
/// Capability execution will be connected through the executor layer.
@MainActor
@Observable
final class AgentTaskRuntime {

    // MARK: - State

    private(set) var tasks: [AgentTask] = []


    // MARK: - Task Creation

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

        task.events.append(
            TaskEvent(
                type: .created,
                message: "Task created"
            )
        )

        tasks.append(task)

        return task
    }


    // MARK: - Task Lookup

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }


    // MARK: - Planning

    /// Attaches an already validated TaskPlan produced by TaskPlanner.
    ///
    /// This is the preferred path when a brand-new AgentTask receives
    /// its initial execution plan.
    ///
    /// TaskPlanner is responsible for:
    /// - structured-output validation
    /// - dependency validation
    /// - internal step UUID generation
    /// - planner metadata materialization
    ///
    /// AgentTaskRuntime only accepts the resulting trusted TaskPlan.
    func attachPlan(
        taskId: UUID,
        plan: TaskPlan
    ) {

        mutate(taskId) { task in

            task.plan = plan
            task.status = .pending
            task.failureReason = nil

            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0

            task.events.append(
                TaskEvent(
                    type: .planned,
                    message: "Plan attached: \(plan.summary)"
                )
            )
        }
    }


    /// Replaces an existing plan and increments plan version.
    ///
    /// This will later be used by the replanning engine when:
    /// - a step repeatedly fails
    /// - assumptions become invalid
    /// - new information changes the strategy
    /// - the Critic requests replanning
    func replacePlan(
        taskId: UUID,
        summary: String,
        steps: [PlanStep]
    ) {

        mutate(taskId) { task in

            let nextVersion =
                task.plan.steps.isEmpty
                ? 1
                : task.plan.version + 1

            task.plan = TaskPlan(
                version: nextVersion,
                summary: summary,
                steps: steps
            )

            task.status = .pending
            task.failureReason = nil

            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0

            if nextVersion > 1 {
                task.executionState.replanCount += 1
            }

            task.events.append(
                TaskEvent(
                    type: nextVersion == 1 ? .planned : .replanned,
                    message: summary
                )
            )
        }
    }


    // MARK: - Task Lifecycle

    func start(taskId: UUID) {

        mutate(taskId) { task in

            guard ![
                .completed,
                .cancelled
            ].contains(task.status) else {
                return
            }

            guard !task.plan.steps.isEmpty else {
                task.status = .failed
                task.failureReason = "Cannot start task without an execution plan."

                task.events.append(
                    TaskEvent(
                        type: .failed,
                        message: "Task cannot start because no execution plan exists."
                    )
                )

                return
            }

            if task.startedAt == nil {
                task.startedAt = Date()
            }

            task.status = .running

            task.executionState.lastHeartbeatAt = Date()

            task.events.append(
                TaskEvent(
                    type: .started,
                    message: "Task execution started"
                )
            )
        }
    }


    func pause(
        taskId: UUID,
        reason: String = "Paused"
    ) {

        mutate(taskId) { task in

            guard
                task.status == .running ||
                task.status == .waitingForDependency ||
                task.status == .waitingForApproval
            else {
                return
            }

            task.status = .paused

            task.events.append(
                TaskEvent(
                    type: .paused,
                    message: reason
                )
            )
        }
    }


    func resume(taskId: UUID) {

        mutate(taskId) { task in

            guard task.status == .paused else {
                return
            }

            task.status = .running

            task.executionState.lastHeartbeatAt = Date()

            task.events.append(
                TaskEvent(
                    type: .resumed,
                    message: "Task resumed"
                )
            )
        }
    }


    func cancel(
        taskId: UUID,
        reason: String = "Cancelled by user"
    ) {

        mutate(taskId) { task in

            guard ![
                .completed,
                .cancelled
            ].contains(task.status) else {
                return
            }

            task.status = .cancelled
            task.completedAt = Date()

            task.executionState.currentStepId = nil

            task.events.append(
                TaskEvent(
                    type: .cancelled,
                    message: reason
                )
            )
        }
    }


    // MARK: - Step Selection

    /// Returns the next step whose dependencies have all completed.
    ///
    /// IMPORTANT:
    /// This method only determines dependency eligibility.
    ///
    /// It does NOT authorize execution.
    ///
    /// Before actual execution the future executor/policy layer must still
    /// evaluate:
    ///
    /// - riskLevel
    /// - requiresApproval
    /// - standing permissions
    /// - Policy Engine rules
    /// - execution budget
    /// - background eligibility
    /// - capability availability
    func nextRunnableStep(
        taskId: UUID
    ) -> PlanStep? {

        guard let task = task(id: taskId) else {
            return nil
        }

        guard task.status == .running else {
            return nil
        }

        if let nextEligibleRunAt =
            task.executionState.nextEligibleRunAt,
           nextEligibleRunAt > Date() {

            return nil
        }

        let completedStepIds = Set(
            task.plan.steps
                .filter {
                    $0.status == .completed
                }
                .map(\.id)
        )

        return task.plan.steps
            .sorted {
                $0.order < $1.order
            }
            .first { step in

                guard
                    step.status == .pending ||
                    step.status == .ready
                else {
                    return false
                }

                return step.dependencyStepIds
                    .allSatisfy {
                        completedStepIds.contains($0)
                    }
            }
    }


    // MARK: - Step Lifecycle

    func markStepRunning(
        taskId: UUID,
        stepId: UUID
    ) {

        mutate(taskId) { task in

            guard task.status == .running else {
                return
            }

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            let step = task.plan.steps[index]

            guard
                step.status == .pending ||
                step.status == .ready
            else {
                return
            }

            task.status = .running

            task.executionState.currentStepId = stepId
            task.executionState.lastHeartbeatAt = Date()

            task.plan.steps[index].status = .running
            task.plan.steps[index].attemptCount += 1

            if task.plan.steps[index].startedAt == nil {
                task.plan.steps[index].startedAt = Date()
            }

            task.events.append(
                TaskEvent(
                    type: .progress,
                    message:
                        "Started step \(task.plan.steps[index].order): "
                        + task.plan.steps[index].title
                )
            )
        }
    }


    func markStepCompleted(
        taskId: UUID,
        stepId: UUID,
        resultSummary: String? = nil
    ) {

        mutate(taskId) { task in

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            task.plan.steps[index].status = .completed
            task.plan.steps[index].completedAt = Date()
            task.plan.steps[index].resultSummary = resultSummary
            task.plan.steps[index].lastError = nil

            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures = 0
            task.executionState.lastHeartbeatAt = Date()
            task.executionState.nextEligibleRunAt = nil

            task.events.append(
                TaskEvent(
                    type: .progress,
                    message:
                        "Completed step \(task.plan.steps[index].order): "
                        + task.plan.steps[index].title
                )
            )

            let unfinishedSteps =
                task.plan.steps.contains {

                    ![
                        .completed,
                        .skipped,
                        .cancelled
                    ].contains($0.status)
                }

            if unfinishedSteps {

                task.status = .running

            } else {

                task.status = .completed
                task.completedAt = Date()

                task.events.append(
                    TaskEvent(
                        type: .completed,
                        message: "All plan steps completed"
                    )
                )
            }
        }
    }


    func markStepFailed(
        taskId: UUID,
        stepId: UUID,
        error: String
    ) {

        mutate(taskId) { task in

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            task.plan.steps[index].lastError = error

            task.executionState.currentStepId = nil
            task.executionState.consecutiveFailures += 1
            task.executionState.lastHeartbeatAt = Date()

            let allowedAttempts = min(
                task.plan.steps[index].maxAttempts,
                task.budget.maxRetriesPerStep
            )

            if task.plan.steps[index].attemptCount < allowedAttempts {

                task.plan.steps[index].status = .pending

                task.events.append(
                    TaskEvent(
                        type: .retry,
                        message:
                            "Step will retry: "
                            + task.plan.steps[index].title
                            + " — \(error)"
                    )
                )

            } else {

                task.plan.steps[index].status = .failed

                task.status = .failed
                task.failureReason = error
                task.completedAt = Date()

                task.events.append(
                    TaskEvent(
                        type: .failed,
                        message:
                            "Step exhausted retries: "
                            + task.plan.steps[index].title
                            + " — \(error)"
                    )
                )
            }
        }
    }


    // MARK: - Approval State

    /// Marks a step as waiting for explicit approval.
    ///
    /// This does NOT create or grant an ApprovalGate permission.
    /// The future Policy/Approval integration remains the source of truth.
    func markStepWaitingForApproval(
        taskId: UUID,
        stepId: UUID
    ) {

        mutate(taskId) { task in

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            task.plan.steps[index].status = .waitingForApproval
            task.status = .waitingForApproval

            task.executionState.currentStepId = stepId

            task.events.append(
                TaskEvent(
                    type: .approvalRequested,
                    message:
                        "Approval required for step "
                        + "\(task.plan.steps[index].order): "
                        + task.plan.steps[index].title
                )
            )
        }
    }


    /// Returns a step to executable state after the external
    /// ApprovalGate confirms permission.
    ///
    /// IMPORTANT:
    /// This function must only be called by trusted approval logic.
    func markStepApprovalGranted(
        taskId: UUID,
        stepId: UUID
    ) {

        mutate(taskId) { task in

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            guard
                task.plan.steps[index].status ==
                    .waitingForApproval
            else {
                return
            }

            task.plan.steps[index].status = .ready

            task.status = .running

            task.executionState.currentStepId = nil
            task.executionState.lastHeartbeatAt = Date()

            task.events.append(
                TaskEvent(
                    type: .approvalGranted,
                    message:
                        "Approval granted for step "
                        + "\(task.plan.steps[index].order)"
                )
            )
        }
    }


    func markStepApprovalRejected(
        taskId: UUID,
        stepId: UUID,
        reason: String = "Approval rejected"
    ) {

        mutate(taskId) { task in

            guard let index =
                    task.plan.steps.firstIndex(
                        where: {
                            $0.id == stepId
                        }
                    )
            else {
                return
            }

            task.plan.steps[index].status = .cancelled

            task.status = .paused

            task.executionState.currentStepId = nil

            task.events.append(
                TaskEvent(
                    type: .approvalRejected,
                    message: reason
                )
            )
        }
    }


    // MARK: - Checkpoints

    func checkpoint(
        taskId: UUID,
        summary: String,
        nextAction: String? = nil
    ) {

        mutate(taskId) { task in

            let checkpoint = TaskCheckpoint(
                taskId: task.id,
                stepId:
                    task.executionState.currentStepId,
                summary: summary,
                nextAction: nextAction
            )

            task.executionState.lastCheckpoint =
                checkpoint

            task.executionState.lastHeartbeatAt =
                Date()

            task.events.append(
                TaskEvent(
                    type: .checkpoint,
                    message: summary
                )
            )
        }
    }


    // MARK: - Heartbeat

    func heartbeat(
        taskId: UUID,
        nextEligibleRunAt: Date? = nil
    ) {

        mutate(taskId) { task in

            task.executionState.lastHeartbeatAt =
                Date()

            task.executionState.nextEligibleRunAt =
                nextEligibleRunAt
        }
    }


    // MARK: - Progress

    func progress(taskId: UUID) -> Double {

        guard let task = task(id: taskId) else {
            return 0
        }

        guard !task.plan.steps.isEmpty else {
            return 0
        }

        let completedCount =
            task.plan.steps.filter {
                $0.status == .completed ||
                $0.status == .skipped
            }.count

        return Double(completedCount)
            / Double(task.plan.steps.count)
    }


    // MARK: - Internal Mutation

    private func mutate(
        _ taskId: UUID,
        _ body: (inout AgentTask) -> Void
    ) {

        guard let index =
                tasks.firstIndex(
                    where: {
                        $0.id == taskId
                    }
                )
        else {
            return
        }

        body(&tasks[index])

        tasks[index].updatedAt = Date()
        tasks[index].plan.updatedAt = Date()
    }
}
