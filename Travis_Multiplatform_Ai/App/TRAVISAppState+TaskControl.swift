import Foundation

@MainActor
extension TRAVISAppState {
    func resolveRuntimeTask(reference: String?) -> AgentTaskResolver.Resolution {
        AgentTaskResolver().resolve(reference, in: taskRuntime.tasks)
    }

    /// Handles explicit slash commands immediately and natural-language
    /// runtime control semantically. Returns true when normal capability
    /// routing must stop because this message was consumed as system control.
    func handleSystemIntent(_ text: String, recentHistory: [ChatMessage]) async -> Bool {
        let router = SystemIntentRouter()
        let intent = await router.classify(text, recentHistory: recentHistory)
        switch intent {
        case .none:
            return false
        case .listTasks:
            await orchestrator.route("/tasks", liveSessionId: currentSessionId, recentHistory: recentHistory)
        case .taskStatus(let reference):
            await orchestrator.route(command("/task-status", reference), liveSessionId: currentSessionId, recentHistory: recentHistory)
        case .taskLog(let reference):
            await orchestrator.route(command("/task-log", reference), liveSessionId: currentSessionId, recentHistory: recentHistory)
        case .run(let reference):
            runAutonomousTask(reference: reference, continuous: false)
        case .auto(let reference):
            runAutonomousTask(reference: reference, continuous: true)
        case .resume(let reference):
            resumeAutonomousTask(reference: reference)
        case .retry(let reference):
            retryAutonomousTask(reference: reference)
        case .cancel(let reference):
            cancelAutonomousTask(reference: reference)
        case .schedulerCycle:
            runSchedulerCycle()
        }
        return true
    }

    func runAutonomousTask(reference: String?, continuous: Bool) {
        guard let task = resolvedTaskForMutation(reference, action: continuous ? "auto" : "run") else { return }
        guard task.status == .running else {
            addAssistantMessage("Το autonomous task \(shortTaskId(task)) δεν είναι running (status: \(task.status.rawValue)).")
            return
        }
        let recentHistory = Array(chatMessages.suffix(Self.runtimeControlContextWindow))
        isProcessing = true
        lastResponseSummary = "Executing task \(shortTaskId(task))…"
        Task {
            defer { isProcessing = false }
            do {
                if continuous {
                    let report = try await taskExecutor.executeUntilBlocked(taskId: task.id, recentHistory: recentHistory, maxStepsPerCycle: 8)
                    addAssistantMessage(renderRunReport(report))
                } else {
                    _ = try await taskExecutor.executeNextStep(taskId: task.id, recentHistory: recentHistory)
                    guard let updated = taskRuntime.task(id: task.id) else { throw RuntimeIntegrationControlError.taskNotFound }
                    addAssistantMessage(renderStepResult(updated))
                }
            } catch {
                addAssistantMessage("Autonomous runtime error: \(error.localizedDescription)")
                lastResponseSummary = error.localizedDescription
            }
        }
    }

    func resumeAutonomousTask(reference: String?) {
        guard let task = resolvedTaskForMutation(reference, action: "resume") else { return }
        guard task.status == .paused else {
            addAssistantMessage("Το task \(shortTaskId(task)) δεν είναι paused (status: \(task.status.rawValue)).")
            return
        }
        taskRuntime.resume(taskId: task.id)
        guard let updated = taskRuntime.task(id: task.id) else { return }
        addAssistantMessage("TASK RESUMED\n\n\(shortTaskId(updated)) [\(updated.status.rawValue)] — \(updated.title)\nΜπορεί να συνεχίσει με run/auto.")
    }

    func cancelAutonomousTask(reference: String?) {
        guard let task = resolvedTaskForMutation(reference, action: "cancel") else { return }
        if taskExecutor.isTaskExecuting(task.id) { _ = taskExecutor.requestCancellation(taskId: task.id, reason: "Cancelled by user") }
        else { taskRuntime.cancel(taskId: task.id) }
        addAssistantMessage("TASK CANCELLED\n\n\(shortTaskId(task)) — \(task.title)")
    }

    func retryAutonomousTask(reference: String?) {
        guard let task = resolvedTaskForMutation(reference, action: "retry") else { return }
        guard task.status == .failed else {
            addAssistantMessage("Το task \(shortTaskId(task)) δεν είναι failed (status: \(task.status.rawValue)).")
            return
        }
        guard taskRuntime.prepareRetry(taskId: task.id) else {
            addAssistantMessage("Δεν βρέθηκε failed step που μπορεί να προετοιμαστεί για retry στο task \(shortTaskId(task)).")
            return
        }
        addAssistantMessage("TASK RETRY READY\n\n\(shortTaskId(task)) επανήλθε σε running state και διατήρησε τα verified προηγούμενα steps.")
    }

    func runSchedulerCycle(backgroundOnly: Bool = false) {
        let recentHistory = Array(chatMessages.suffix(Self.runtimeControlContextWindow))
        isProcessing = true
        Task {
            defer { isProcessing = false }
            let scheduler = AgentTaskScheduler(runtime: taskRuntime, executor: taskExecutor)
            let report = await scheduler.runCycle(recentHistory: recentHistory, backgroundOnly: backgroundOnly, maxTasksPerCycle: 4)
            addAssistantMessage("""
            SCHEDULER CYCLE COMPLETE

            CONSIDERED
            \(report.consideredTaskIds.count)

            EXECUTED
            \(report.executedTaskIds.count)

            BUSY / SKIPPED
            \(report.skippedLeasedTaskIds.count)

            STALE HEARTBEATS OBSERVED
            \(report.staleTaskIds.count)
            """)
        }
    }

    private static var runtimeControlContextWindow: Int { 8 }

    private func command(_ base: String, _ reference: String?) -> String {
        guard let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base + " " + reference
    }

    private func resolvedTaskForMutation(_ reference: String?, action: String) -> AgentTask? {
        switch resolveRuntimeTask(reference: reference) {
        case .found(let task): return task
        case .notFound:
            addAssistantMessage("Δεν βρέθηκε autonomous task για \(action). Χρησιμοποίησε /tasks.")
            return nil
        case .ambiguous(let tasks):
            let rows = tasks.prefix(8).map { "\(shortTaskId($0)) [\($0.status.rawValue)] — \($0.title)" }.joined(separator: "\n")
            addAssistantMessage("Βρήκα περισσότερα από ένα tasks. Δεν θα επιλέξω αυθαίρετα:\n\n\(rows)\n\nΔώσε το short ID.")
            return nil
        }
    }

    private func shortTaskId(_ task: AgentTask) -> String { String(task.id.uuidString.prefix(8)) }

    private func renderStepResult(_ task: AgentTask) -> String {
        let progress = Int(taskRuntime.progress(taskId: task.id) * 100)
        let next = taskRuntime.nextRunnableStep(taskId: task.id)
        return "RUNTIME STEP RESULT\n\nTASK\n\(task.id.uuidString)\n\nSTATUS\n\(task.status.rawValue)\n\nPROGRESS\n\(progress)%\n\nNEXT RUNNABLE STEP\n\(next.map { "#\($0.order) — \($0.title)" } ?? "κανένα")"
    }

    private func renderRunReport(_ report: AutonomousRunReport) -> String {
        "AUTONOMOUS RUN STOPPED\n\nTASK\n\(report.taskId.uuidString)\n\nSTOP REASON\n\(report.stopReason.rawValue)\n\nSTEPS ATTEMPTED THIS CYCLE\n\(report.stepsAttempted)\n\nPROGRESS\n\(Int(report.progress * 100))%\n\nLAST CHECKPOINT\n\(report.lastCheckpoint ?? "κανένα")\n\nNEXT RUNNABLE STEP\n\(report.nextStepTitle ?? "κανένα")"
    }
}

private enum RuntimeIntegrationControlError: LocalizedError {
    case taskNotFound
    var errorDescription: String? { "Το runtime task δεν βρέθηκε μετά την εκτέλεση." }
}
