import Foundation

@MainActor
enum RuntimeMaintenance {
    struct Result: Equatable {
        var beforeCount: Int
        var afterCount: Int
        var removedCount: Int
    }

    static func pruneStoredHistory(appState: TRAVISAppState, policy: MissionRetentionPolicy = .init()) throws -> Result {
        let current = appState.taskRuntime.tasks
        let pruned = policy.pruned(current)
        guard pruned.count != current.count else { return Result(beforeCount: current.count, afterCount: current.count, removedCount: 0) }
        try AgentTaskStore.shared.save(pruned)
        appState.taskRuntime.reloadFromDisk()
        return Result(beforeCount: current.count, afterCount: pruned.count, removedCount: current.count - pruned.count)
    }
}
