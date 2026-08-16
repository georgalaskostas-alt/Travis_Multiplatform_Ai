import Foundation
import Observation

/// Coordinates fair, bounded execution across multiple autonomous tasks.
/// The scheduler never invents work: AgentTaskRuntime remains the canonical
/// lifecycle/state machine and AgentTaskExecutor remains the only step executor.
@MainActor
@Observable
final class AgentTaskScheduler {
    struct CycleReport: Hashable {
        let consideredTaskIds: [UUID]
        let executedTaskIds: [UUID]
        let skippedLeasedTaskIds: [UUID]
        let staleTaskIds: [UUID]
        let pausedOrphanTaskIds: [UUID]
    }

    private let runtime: AgentTaskRuntime
    private let executor: AgentTaskExecutor
    private let supervisor: AgentRuntimeSupervisor

    private(set) var isRunningCycle = false
    private(set) var lastCycleAt: Date?
    private(set) var lastCycleReport: CycleReport?

    init(runtime: AgentTaskRuntime, executor: AgentTaskExecutor) {
        self.runtime = runtime
        self.executor = executor
        self.supervisor = AgentRuntimeSupervisor(runtime: runtime, executor: executor)
    }

    /// Executes at most one verified step per selected task. This keeps a
    /// single scheduler cycle fair: one long project cannot monopolize all
    /// available execution turns while other runnable projects wait.
    @discardableResult
    func runCycle(
        recentHistory: [ChatMessage] = [],
        backgroundOnly: Bool = false,
        maxTasksPerCycle: Int = 4,
        staleHeartbeatSeconds: TimeInterval = 300
    ) async -> CycleReport {
        guard !isRunningCycle else {
            return lastCycleReport ?? CycleReport(
                consideredTaskIds: [],
                executedTaskIds: [],
                skippedLeasedTaskIds: [],
                staleTaskIds: [],
                pausedOrphanTaskIds: []
            )
        }

        isRunningCycle = true
        defer {
            isRunningCycle = false
            lastCycleAt = Date()
        }

        let health = supervisor.inspect(
            heartbeatOlderThan: staleHeartbeatSeconds
        )

        let candidates = runtime.dispatchableTasks(
            backgroundOnly: backgroundOnly,
            limit: max(1, maxTasksPerCycle)
        )

        var executed: [UUID] = []
        var skippedLeased: [UUID] = []

        for task in candidates {
            if executor.isTaskExecuting(task.id) {
                skippedLeased.append(task.id)
                continue
            }

            do {
                _ = try await executor.executeNextStep(
                    taskId: task.id,
                    recentHistory: recentHistory
                )
                executed.append(task.id)
            } catch AgentTaskExecutorError.taskAlreadyExecuting {
                skippedLeased.append(task.id)
            } catch {
                // The executor persists canonical retry/failure state. A single
                // task failure must not starve unrelated runnable tasks.
                continue
            }
        }

        let report = CycleReport(
            consideredTaskIds: candidates.map(\.id),
            executedTaskIds: executed,
            skippedLeasedTaskIds: skippedLeased,
            staleTaskIds: health.staleTaskIds,
            pausedOrphanTaskIds: health.pausedOrphanTaskIds
        )
        lastCycleReport = report
        return report
    }
}
