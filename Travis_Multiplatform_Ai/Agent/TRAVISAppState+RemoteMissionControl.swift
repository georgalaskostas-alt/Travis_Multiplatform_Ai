import Foundation

@MainActor
extension TRAVISAppState {
    /// Handles deterministic control messages sent by the connected iPhone.
    /// These commands intentionally bypass natural-language routing so task
    /// controls remain reliable even when cloud AI is unavailable.
    @discardableResult
    func handleRemoteMissionControlCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("/remote-pause-task ") {
            guard let id = remoteTaskID(from: trimmed, prefix: "/remote-pause-task ") else { return true }
            remotePauseTask(id)
            return true
        }
        if lower.hasPrefix("/remote-resume-task ") {
            guard let id = remoteTaskID(from: trimmed, prefix: "/remote-resume-task ") else { return true }
            remoteResumeTask(id)
            return true
        }
        if lower.hasPrefix("/remote-cancel-task ") {
            guard let id = remoteTaskID(from: trimmed, prefix: "/remote-cancel-task ") else { return true }
            remoteCancelTask(id)
            return true
        }
        if lower.hasPrefix("/remote-delete-task ") {
            guard let id = remoteTaskID(from: trimmed, prefix: "/remote-delete-task ") else { return true }
            remoteDeleteTask(id)
            return true
        }
        if lower == "/remote-delete-all-tasks" {
            remoteDeleteAllTasks()
            return true
        }
        return false
    }

    private func remoteTaskID(from command: String, prefix: String) -> UUID? {
        let raw = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let full = UUID(uuidString: raw) { return full }
        let normalized = raw.lowercased()
        let matches = taskRuntime.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(normalized) }
        guard matches.count == 1 else {
            lastResponseSummary = matches.isEmpty ? "Remote task not found" : "Remote task reference is ambiguous"
            return nil
        }
        return matches[0].id
    }

    private func remotePauseTask(_ id: UUID) {
        guard let task = taskRuntime.task(id: id) else { lastResponseSummary = "Task not found"; return }
        if taskExecutor.isTaskExecuting(id) {
            _ = taskExecutor.requestCancellation(taskId: id, reason: "Paused from iPhone")
        } else {
            taskRuntime.pause(taskId: id, reason: "Paused from iPhone")
        }
        lastResponseSummary = "Paused \(String(task.id.uuidString.prefix(8))) — \(task.title)"
    }

    private func remoteResumeTask(_ id: UUID) {
        guard let task = taskRuntime.task(id: id) else { lastResponseSummary = "Task not found"; return }
        guard task.status == .paused else {
            lastResponseSummary = "Task \(String(id.uuidString.prefix(8))) is not paused"
            return
        }
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
        guard canSafelyRewriteRuntimeStore else {
            lastResponseSummary = "Finish or cancel active missions before deleting task history"
            return
        }
        do {
            let remaining = taskRuntime.tasks.filter { $0.id != id }
            try AgentTaskStore.shared.save(remaining)
            taskRuntime.reloadFromDisk()
            lastResponseSummary = "Deleted \(String(task.id.uuidString.prefix(8))) — \(task.title)"
        } catch {
            lastResponseSummary = "Task deletion failed: \(error.localizedDescription)"
        }
    }

    private func remoteDeleteAllTasks() {
        guard canSafelyRewriteRuntimeStore else {
            lastResponseSummary = "Finish or cancel active missions before deleting all task history"
            return
        }
        do {
            try AgentTaskStore.shared.save([])
            taskRuntime.reloadFromDisk()
            lastResponseSummary = "All runtime task history deleted"
        } catch {
            lastResponseSummary = "Delete all failed: \(error.localizedDescription)"
        }
    }

    private var canSafelyRewriteRuntimeStore: Bool {
        let activeStatuses: Set<AgentTaskStatus> = [
            .pending, .planning, .running, .waitingForApproval,
            .waitingForDependency, .paused
        ]
        return !taskRuntime.tasks.contains { activeStatuses.contains($0.status) || taskExecutor.isTaskExecuting($0.id) }
    }
}
