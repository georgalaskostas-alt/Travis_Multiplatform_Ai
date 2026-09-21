import Foundation

@MainActor
extension TRAVISAppState {

    // MARK: - Control Plane V2

    @discardableResult
    func handleControlPlaneCommand(
        _ command: TravisControlCommand,
        onDurableClaim: (() -> Void)? = nil
    ) async -> TravisControlCommandResult {
        let receipts = TravisControlCommandReceiptStore.shared

        // Expired commands never receive permission to execute.
        if command.isExpired {
            let result = TravisControlCommandResult(
                commandID: command.id,
                status: .expired,
                message: "Control command expired before execution."
            )

            do {
                let claim = try await receipts.claim(
                    commandID: command.id,
                    nonce: command.nonce,
                    commandType: command.type.rawValue,
                    sourceDeviceID: command.deviceID,
                    payload: command.payload
                )

                switch claim {
                case .execute:
                    try await receipts.finish(
                        commandID: command.id,
                        status: result.status,
                        message: result.message
                    )

                case .duplicate(let receipt):
                    return cachedControlPlaneResult(
                        commandID: command.id,
                        receipt: receipt
                    )

                case .conflict:
                    return TravisControlCommandResult(
                        commandID: command.id,
                        status: .failed,
                        message: "Control command ID conflict: commandID was previously claimed with a different nonce."
                    )
                }
            } catch {
                return TravisControlCommandResult(
                    commandID: command.id,
                    status: .failed,
                    message: "Control Plane receipt persistence failed: \(error.localizedDescription)"
                )
            }

            return result
        }

        let claim: TravisControlCommandReceiptStore.Claim

        do {
            claim = try await receipts.claim(
                commandID: command.id,
                nonce: command.nonce,
                commandType: command.type.rawValue,
                sourceDeviceID: command.deviceID,
                payload: command.payload
            )
        } catch {
            // Fail closed: if we cannot durably claim the command, no
            // side effect is allowed to execute.
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Control Plane receipt persistence failed: \(error.localizedDescription)"
            )
        }

        switch claim {
        case .duplicate(let receipt):
            return cachedControlPlaneResult(
                commandID: command.id,
                receipt: receipt
            )

        case .conflict:
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Control command ID conflict: commandID was previously claimed with a different nonce."
            )

        case .execute:
            onDurableClaim?()
        }

        // From this point onward this invocation is the only invocation
        // permitted to perform the command's side effects.
        let result = await executeControlPlaneCommand(command)

        do {
            try await receipts.finish(
                commandID: command.id,
                status: result.status,
                message: result.message
            )
        } catch {
            // The command may already have produced a side effect.
            // Never retry it automatically when terminal receipt persistence
            // fails; require reconciliation instead.
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Command executed but terminal receipt persistence failed; reconciliation required: \(error.localizedDescription)"
            )
        }

        return result
    }

    private func cachedControlPlaneResult(
        commandID: UUID,
        receipt: TravisControlCommandReceiptStore.Receipt
    ) -> TravisControlCommandResult {
        if let status = receipt.resultStatus,
           let message = receipt.resultMessage {
            return TravisControlCommandResult(
                commandID: commandID,
                status: status,
                message: message
            )
        }

        // An executing receipt without a terminal result is deliberately
        // not re-executed. The original invocation may still be running,
        // or the process may have stopped after the side effect but before
        // persisting the terminal result.
        return TravisControlCommandResult(
            commandID: commandID,
            status: .executing,
            message: "Duplicate command suppressed: the original execution is still unresolved."
        )
    }

    private func executeControlPlaneCommand(_ command: TravisControlCommand) async -> TravisControlCommandResult {
        guard !command.isExpired else {
            return TravisControlCommandResult(
                commandID: command.id,
                status: .expired,
                message: "Control command expired before execution."
            )
        }

        let taskID = command.payload["taskID"]

        // Task-scoped commands require a non-empty task reference. Validate
        // this before translating into the legacy command surface so malformed
        // Control Plane requests can never be reported as successful.
        if [.pauseTask, .resumeTask, .cancelTask, .deleteTask].contains(command.type) {
            guard let taskID, !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return TravisControlCommandResult(
                    commandID: command.id,
                    status: .failed,
                    message: "Control command requires a non-empty taskID."
                )
            }
        }

        // Reject malformed payloads before any runtime mutation. Unknown keys
        // are not tolerated on safety/control commands.
        let allowedKeys: Set<String>
        switch command.type {
        case .pauseTask, .resumeTask, .cancelTask, .deleteTask:
            allowedKeys = ["taskID"]
        case .deleteFinished, .requestStatus:
            allowedKeys = []
        case .killSwitch:
            allowedKeys = ["enabled"]
        case .mission:
            allowedKeys = ["goal"]
        }
        guard Set(command.payload.keys).isSubset(of: allowedKeys) else {
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Control command contains unsupported payload fields."
            )
        }

        let legacyCommand: String?

        switch command.type {
        case .pauseTask:
            legacyCommand = taskID.map { "/remote-pause-task \($0)" }

        case .resumeTask:
            legacyCommand = taskID.map { "/remote-resume-task \($0)" }

        case .cancelTask:
            legacyCommand = taskID.map { "/remote-cancel-task \($0)" }

        case .deleteTask:
            legacyCommand = taskID.map { "/remote-delete-task \($0)" }

        case .deleteFinished:
            legacyCommand = "/remote-delete-all-tasks"

        case .killSwitch:
            guard let rawEnabled = command.payload["enabled"]?.lowercased(),
                  ["true", "false"].contains(rawEnabled) else {
                return TravisControlCommandResult(
                    commandID: command.id,
                    status: .failed,
                    message: "Kill switch command requires enabled=true or enabled=false."
                )
            }

            let enabled = rawEnabled == "true"
            let coordinator = AlwaysOnRuntimeCoordinator.shared

            if enabled {
                coordinator.emergencyStop()
            } else {
                coordinator.clearEmergencyStop()
            }

            if let error = coordinator.lastError, !error.isEmpty {
                return TravisControlCommandResult(
                    commandID: command.id,
                    status: .failed,
                    message: "Kill switch operation failed: \(error)"
                )
            }

            // The control file is written immediately, but the authoritative
            // kill-switch state is published asynchronously by the headless
            // worker in worker-heartbeat.json.
            let verificationDeadline = Date().addingTimeInterval(5)
            var actualState: Bool?

            repeat {
                coordinator.worker.refresh()
                actualState = coordinator.worker.snapshot?.killSwitch

                if actualState == enabled {
                    break
                }

                if Date() >= verificationDeadline || Task.isCancelled {
                    break
                }

                try? await Task.sleep(for: .milliseconds(250))
            } while true

            guard actualState == enabled else {
                let reportedState = actualState.map(String.init) ?? "unknown"
                return TravisControlCommandResult(
                    commandID: command.id,
                    status: .failed,
                    message: "Kill switch verification timed out. Requested \(enabled), worker reports \(reportedState)."
                )
            }

            lastResponseSummary = enabled
                ? "EMERGENCY STOP ACTIVE — Always-On jobs paused"
                : "Emergency stop cleared — jobs remain paused until explicitly resumed"

            return TravisControlCommandResult(
                commandID: command.id,
                status: .completed,
                message: lastResponseSummary
            )

        default:
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Unsupported Control Plane command: \(command.type.rawValue)"
            )
        }

        guard let legacyCommand else {
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Missing taskID payload."
            )
        }

        let handled = handleRemoteMissionControlCommand(legacyCommand)

        guard handled else {
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: "Control command was not handled."
            )
        }

        // Legacy remote-control helpers report operational failures through
        // lastResponseSummary. Do not turn those failures into a successful
        // Control Plane receipt.
        let normalizedSummary = lastResponseSummary.lowercased()
        let failureMarkers = [
            "not found",
            "ambiguous",
            "failed",
            "not paused",
            "not failed",
            "no failed step",
            "cannot be deleted",
            "persistence is unavailable",
            "cancellation was not accepted"
        ]
        if failureMarkers.contains(where: { normalizedSummary.contains($0) }) {
            return TravisControlCommandResult(
                commandID: command.id,
                status: .failed,
                message: lastResponseSummary
            )
        }

        return TravisControlCommandResult(
            commandID: command.id,
            status: .completed,
            message: lastResponseSummary
        )
    }
    @discardableResult
    func handleRemoteMissionControlCommand(_ text: String) -> Bool {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines);let lower=trimmed.lowercased()
        if lower.hasPrefix("/remote-pause-task "){if let id=remoteTaskID(from:trimmed,prefix:"/remote-pause-task "){remotePauseTask(id)};return true}
        if lower.hasPrefix("/remote-resume-task "){if let id=remoteTaskID(from:trimmed,prefix:"/remote-resume-task "){remoteResumeTask(id)};return true}
        if lower.hasPrefix("/remote-cancel-task "){if let id=remoteTaskID(from:trimmed,prefix:"/remote-cancel-task "){remoteCancelTask(id)};return true}
        if lower.hasPrefix("/remote-retry-task "){if let id=remoteTaskID(from:trimmed,prefix:"/remote-retry-task "){remoteRetryTask(id)};return true}
        if lower.hasPrefix("/remote-delete-task "){if let id=remoteTaskID(from:trimmed,prefix:"/remote-delete-task "){remoteDeleteTask(id)};return true}
        if lower == "/remote-delete-all-tasks"{remoteDeleteAllTasks();return true};return false
    }
    private func remoteTaskID(from command:String,prefix:String)->UUID?{let raw=String(command.dropFirst(prefix.count)).trimmingCharacters(in:.whitespacesAndNewlines);if let full=UUID(uuidString:raw){return full};let normalized=raw.lowercased();let matches=taskRuntime.tasks.filter{$0.id.uuidString.lowercased().hasPrefix(normalized)};guard matches.count==1 else{lastResponseSummary=matches.isEmpty ? "Remote task not found":"Remote task reference is ambiguous";return nil};return matches[0].id}
    private func headlessJobID(for taskID:UUID)->UUID?{
        // Prefer the worker's currently controllable job for this mission.
        // A mission can have older stopped worker jobs with the same sourceTaskID;
        // selecting one of those makes RESUME look successful while nothing runs.
        AlwaysOnWorkerMonitor.shared.refresh()
        let sourceID=taskID.uuidString
        let matches=AlwaysOnWorkerMonitor.shared.serviceJobs.filter{
            $0.kind=="headlessMission" &&
            $0.sourceTaskID?.caseInsensitiveCompare(sourceID) == .orderedSame
        }
        let controllable=matches.last{
            let state=$0.state.lowercased()
            return ["running","scheduled","sleeping","paused","failed"].contains(state) || $0.enabled
        }
        return controllable?.id ?? matches.last?.id ?? AlwaysOnWorkerMonitor.shared.serviceJobID(forSourceTaskID:taskID)
    }
    private func remotePauseTask(_ id:UUID){guard let task=taskRuntime.task(id:id) else{lastResponseSummary="Task not found";return};if let workerID=headlessJobID(for:id){do{try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:"pause",jobID:workerID);if task.status == .running{taskRuntime.pause(taskId:id,reason:"Paused with Always-On worker from iPhone");if let persistenceError=taskRuntime.persistenceError{lastResponseSummary="Pause failed because runtime persistence is unavailable: \(persistenceError)";return}};lastResponseSummary="Pausing headless mission \(String(task.id.uuidString.prefix(8)))"}catch{lastResponseSummary="Headless pause failed: \(error.localizedDescription)"};return};if taskExecutor.isTaskExecuting(id){guard taskExecutor.requestCancellation(taskId:id,reason:"Paused from iPhone") else{lastResponseSummary="Pause failed because task cancellation was not accepted";return}}else{taskRuntime.pause(taskId:id,reason:"Paused from iPhone");if let persistenceError=taskRuntime.persistenceError{lastResponseSummary="Pause failed because runtime persistence is unavailable: \(persistenceError)";return}};lastResponseSummary="Paused \(String(task.id.uuidString.prefix(8))) — \(task.title)"}
    private func remoteResumeTask(_ id:UUID){guard let task=taskRuntime.task(id:id) else{lastResponseSummary="Task not found";return};if let workerID=headlessJobID(for:id){do{try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:"resume",jobID:workerID);/* Headless ownership is exclusive. Keep the GUI runtime paused so AUTO/foreground execution can never race the worker over the same mission. Worker state is authoritative until reconciliation completes. */lastResponseSummary="Resuming Always-On worker mission \(String(task.id.uuidString.prefix(8)))"}catch{lastResponseSummary="Headless resume failed: \(error.localizedDescription)"};return};guard task.status == .paused else{lastResponseSummary="Task \(String(id.uuidString.prefix(8))) is not paused";return};taskRuntime.resume(taskId:id);if let persistenceError=taskRuntime.persistenceError{lastResponseSummary="Resume failed because runtime persistence is unavailable: \(persistenceError)";return};lastResponseSummary="Resuming \(String(id.uuidString.prefix(8))) — \(task.title)";runAutonomousTask(reference:id.uuidString,continuous:true)}
    private func remoteRetryTask(_ id:UUID){guard let task=taskRuntime.task(id:id) else{lastResponseSummary="Task not found";return};if let workerID=headlessJobID(for:id){do{try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:"retry",jobID:workerID);lastResponseSummary="Retrying Always-On worker mission \(String(task.id.uuidString.prefix(8)))"}catch{lastResponseSummary="Headless retry failed: \(error.localizedDescription)"};return};guard task.status == .failed else{lastResponseSummary="Task \(String(id.uuidString.prefix(8))) is not failed";return};guard taskRuntime.prepareRetry(taskId:id) else{lastResponseSummary="No failed step is available to retry";return};lastResponseSummary="Retrying \(String(id.uuidString.prefix(8))) — \(task.title)";runAutonomousTask(reference:id.uuidString,continuous:true)}
    private func remoteCancelTask(_ id:UUID){guard taskRuntime.task(id:id) != nil else{lastResponseSummary="Task not found";return};if let workerID=headlessJobID(for:id){do{try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:"delete",jobID:workerID)}catch{lastResponseSummary="Headless cancel failed: \(error.localizedDescription)";return}};cancelAutonomousTask(reference:id.uuidString);if let persistenceError=taskRuntime.persistenceError{lastResponseSummary="Cancel failed because runtime persistence is unavailable: \(persistenceError)";return};lastResponseSummary="Task cancelled from iPhone"}

    /// History deletion is runtime-native: no reloadFromDisk, so active execution state is never reconstructed or paused as a side effect.
    private func remoteDeleteTask(_ id:UUID){
        guard let task=taskRuntime.task(id:id) else{lastResponseSummary="Task already removed";return}
        guard [.completed,.failed,.cancelled].contains(task.status) else{lastResponseSummary="Active missions cannot be deleted. Cancel or finish the mission first.";return}
        if let workerID=headlessJobID(for:id){
            do {
                try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:"delete",jobID:workerID)
            } catch {
                lastResponseSummary="Headless delete failed: \(error.localizedDescription)"
                return
            }
        }
        let deleted=taskRuntime.deleteTerminalTask(id:id)
        if let persistenceError=taskRuntime.persistenceError {
            lastResponseSummary="Delete failed because runtime persistence is unavailable: \(persistenceError)"
            return
        }
        lastResponseSummary=deleted ? "Deleted \(String(task.id.uuidString.prefix(8))) — \(task.title)":"Task already removed"
    }

    private func remoteDeleteAllTasks(){
        let activeCount=taskRuntime.tasks.filter{![AgentTaskStatus.completed,.failed,.cancelled].contains($0.status)}.count
        let deleted=taskRuntime.deleteAllTerminalTasks()
        if let persistenceError=taskRuntime.persistenceError {
            lastResponseSummary="Delete finished failed because runtime persistence is unavailable: \(persistenceError)"
            return
        }
        lastResponseSummary=activeCount==0 ? "Deleted \(deleted) finished tasks":"Deleted \(deleted) finished tasks; kept \(activeCount) active mission(s)"
    }
}
