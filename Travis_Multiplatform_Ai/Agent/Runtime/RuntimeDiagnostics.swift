import Foundation

struct RuntimeDiagnosticsSnapshot: Codable, Equatable {
    var generatedAt = Date()
    var totalTasks: Int
    var activeTasks: Int
    var completedTasks: Int
    var failedTasks: Int
    var pausedTasks: Int
    var waitingTasks: Int
    var executingTaskIDs: [UUID]
    var health: RuntimeHealthReport
}

@MainActor
enum RuntimeDiagnostics {
    static func snapshot(appState: TRAVISAppState) -> RuntimeDiagnosticsSnapshot {
        let tasks = appState.taskRuntime.tasks
        let normalized: (AgentTaskStatus) -> String = { $0.rawValue.lowercased().filter { $0.isLetter } }
        let activeKeys: Set<String> = ["pending", "planning", "running", "waitingforapproval", "waitingfordependency", "paused"]
        let active = tasks.filter { activeKeys.contains(normalized($0.status)) }
        return RuntimeDiagnosticsSnapshot(
            totalTasks: tasks.count,
            activeTasks: active.count,
            completedTasks: tasks.filter { normalized($0.status) == "completed" }.count,
            failedTasks: tasks.filter { normalized($0.status) == "failed" }.count,
            pausedTasks: tasks.filter { normalized($0.status) == "paused" }.count,
            waitingTasks: tasks.filter { ["waitingforapproval", "waitingfordependency"].contains(normalized($0.status)) }.count,
            executingTaskIDs: tasks.filter { appState.taskExecutor.isTaskExecuting($0.id) }.map(\.id),
            health: RuntimeHealthScanner.scan(appState: appState)
        )
    }
}
