import Foundation

@MainActor
extension TRAVISAppState {
    @discardableResult
    func handleRemoteMissionControlCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("/remote-pause-task ") { if let id = remoteTaskID(from: trimmed, prefix: "/remote-pause-task ") { remotePauseTask(id) }; return true }
        if lower.hasPrefix("/remote-resume-task ") { if let id = remoteTaskID(from: trimmed, prefix: "/remote-resume-task ") { remoteResumeTask(id) }; return true }
        if lower.hasPrefix("/remote-cancel-task ") { if let id = remoteTaskID(from: trimmed, prefix: "/remote-cancel-task ") { remoteCancelTask(id) }; return true }
        if lower.hasPrefix("/remote-delete-task ") { if let id = remoteTaskID(from: trimmed, prefix: "/remote-delete-task ") { remoteDeleteTask(id) }; return true }
        if lower == "/remote-delete-all-tasks" { remoteDeleteAllTasks(); return true }
        return false
    }

    private func remoteTaskID(from command: String, prefix: String) -> UUID? {
        let raw = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let full = UUID(uuidString: raw) { return full }
        let normalized = raw.lowercased()
        let matches = taskRuntime.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(normalized) }
        guard matches.count == 1 else { lastResponseSummary = matches.isEmpty ? "Remote task not found" : "Remote task reference is ambiguous"; return nil }
        return matches[0].id
    }

    private func remotePauseTask(_ id: UUID) {
        guard let task = taskRuntime.task(id: id) else { lastResponseSummary = "Task not found"; return }
        if taskExecutor.isTaskExecuting(id) { _ = taskExecutor.requestCancellation(taskId: id, reason: "Paused from iPhone") }
        else { taskRuntime.pause(taskId: id, reason: "Paused from iPhone") }
        lastResponseSummary = "Paused \(String(task.id.uuidString.prefix(8))) — \(task.title)"
    }

    private func remoteResumeTask(_ id: UUID) {
        guard let task = taskRuntime.task(id: id) else { lastResponseSummary = "Task not found"; return }
        guard task.status == .paused else { lastResponseSummary = "Task \(String(id.uuidString.prefix(8))) is not paused"; return }
        taskRuntime.resume(taskId: id)
        lastResponseSummary = "Resuming \(String(id.uuidString.prefix(8))) — \(task.title)"
        runAutonomousTask(reference: id.uuidString, continuous: true)
    }

    private func remoteCancelTask(_ id: UUID) {
        guard taskRuntime.task(id: id) != nil else { lastResponseSummary = "Task not found"; return }
        cancelAutonomousTask(reference: id.uuidString)
        lastResponseSummary = "Task cancelled from iPhone"
    }

    private func remoteDeleteTask(_ id: UUID) {
        guard let task = taskRuntime.task(id: id) else { lastResponseSummary = "Task already removed"; return }
        do {
            let activeIDs = activeRuntimeTaskIDs
            let deleted = try AgentTaskStore.shared.deleteTask(id: id, activeTaskIDs: activeIDs)
            taskRuntime.reloadFromDisk()
            lastResponseSummary = deleted ? "Deleted \(String(task.id.uuidString.prefix(8))) — \(task.title)" : "Task already removed"
        } catch { lastResponseSummary = "Task deletion failed: \(error.localizedDescription)" }
    }

    private func remoteDeleteAllTasks() {
        do {
            let activeIDs = activeRuntimeTaskIDs
            let deleted = try AgentTaskStore.shared.deleteAll(excluding: activeIDs)
            taskRuntime.reloadFromDisk()
            lastResponseSummary = activeIDs.isEmpty ? "Deleted \(deleted) runtime tasks" : "Deleted \(deleted) finished tasks; kept \(activeIDs.count) active mission(s)"
        } catch { lastResponseSummary = "Delete all failed: \(error.localizedDescription)" }
    }

    private var activeRuntimeTaskIDs: Set<UUID> {
        let activeStatuses: Set<AgentTaskStatus> = [.pending, .planning, .running, .waitingForApproval, .waitingForDependency, .paused]
        return Set(taskRuntime.tasks.filter { activeStatuses.contains($0.status) || taskExecutor.isTaskExecuting($0.id) }.map(\.id))
    }
}
