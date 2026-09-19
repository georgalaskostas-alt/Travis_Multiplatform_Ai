import Foundation
import Observation

/// Supervises long-lived runtime health without duplicating execution logic.
/// A task is only auto-paused as stale when it has no active executor lease;
/// an in-flight capability is therefore never interrupted merely because its
/// heartbeat is old.
@MainActor
@Observable
final class AgentRuntimeSupervisor {
    struct Report: Hashable {
        let inspectedAt: Date
        let staleTaskIds: [UUID]
        let activelyExecutingStaleTaskIds: [UUID]
        let pausedOrphanTaskIds: [UUID]
    }

    private let runtime: AgentTaskRuntime
    private let executor: AgentTaskExecutor

    private(set) var lastReport: Report?

    init(runtime: AgentTaskRuntime, executor: AgentTaskExecutor) {
        self.runtime = runtime
        self.executor = executor
    }

    @discardableResult
    func inspect(
        heartbeatOlderThan interval: TimeInterval = 300,
        now: Date = Date()
    ) -> Report {
        let stale = runtime.staleRunningTasks(
            heartbeatOlderThan: interval,
            now: now
        )

        var active: [UUID] = []
        var paused: [UUID] = []

        for task in stale {
            if executor.isTaskExecuting(task.id) {
                active.append(task.id)
                continue
            }

            runtime.pause(
                taskId: task.id,
                reason: "Supervisor paused stale running task with no active execution lease."
            )
            paused.append(task.id)
        }

        let report = Report(
            inspectedAt: now,
            staleTaskIds: stale.map(\.id),
            activelyExecutingStaleTaskIds: active,
            pausedOrphanTaskIds: paused
        )
        lastReport = report
        return report
    }
}
