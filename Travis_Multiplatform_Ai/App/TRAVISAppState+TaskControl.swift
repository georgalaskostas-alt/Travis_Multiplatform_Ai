import Foundation

@MainActor
extension TRAVISAppState {
    /// Deterministic task lookup shared by explicit runtime-control commands.
    /// UUID/prefix is authoritative; ambiguous natural references never mutate.
    func resolveRuntimeTask(reference: String?) -> AgentTaskResolver.Resolution {
        AgentTaskResolver().resolve(reference, in: taskRuntime.tasks)
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
                    let report = try await taskExecutor.executeUntilBlocked(
                        taskId: task.id,
                        recentHistory: recentHistory,
                        maxStepsPerCycle: 8
                    )
                    addAssistantMessage(renderRunReport(report))
                } else {
                    _ = try await taskExecutor.executeNextStep(
                        taskId: task.id,
                        recentHistory: recentHistory
                    )
                    guard let updated = taskRuntime.task(id: task.id) else {
                        throw RuntimeIntegrationControlError.taskNotFound
                    }
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
        if taskExecutor.isTaskExecuting(task.id) {
            _ = taskExecutor.requestCancellation(taskId: task.id, reason: "Cancelled by user")
        } else {
            taskRuntime.cancel(taskId: task.id)
        }
        addAssistantMessage("TASK CANCELLED\n\n\(shortTaskId(task)) — \(task.title)")
    }

    /// A failed task is not silently reset because exhausted retries may have
    /// side effects. Retry converts only the failed step back to pending and
    /// clears terminal task state after explicit user intent.
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
            let report = await taskScheduler.runCycle(
                recentHistory: recentHistory,
                backgroundOnly: backgroundOnly,
                maxTasksPerCycle: 4
            )
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

    private func resolvedTaskForMutation(_ reference: String?, action: String) -> AgentTask? {
        switch resolveRuntimeTask(reference: reference) {
        case .found(let task):
            return task
        case .notFound:
            addAssistantMessage("Δεν βρέθηκε autonomous task για \(action). Χρησιμοποίησε /tasks.")
            return nil
        case .ambiguous(let tasks):
            let rows = tasks.prefix(8).map {
                "\(shortTaskId($0)) [\($0.status.rawValue)] — \($0.title)"
            }.joined(separator: "\n")
            addAssistantMessage("Βρήκα περισσότερα από ένα tasks. Δεν θα επιλέξω αυθαίρετα:\n\n\(rows)\n\nΔώσε το short ID.")
            return nil
        }
    }

    private func shortTaskId(_ task: AgentTask) -> String {
        String(task.id.uuidString.prefix(8))
    }

    private func renderStepResult(_ task: AgentTask) -> String {
        let progress = Int(taskRuntime.progress(taskId: task.id) * 100)
        let next = taskRuntime.nextRunnableStep(taskId: task.id)
        return """
        RUNTIME STEP RESULT

        TASK
        \(task.id.uuidString)

        STATUS
        \(task.status.rawValue)

        PROGRESS
        \(progress)%

        NEXT RUNNABLE STEP
        \(next.map { "#\($0.order) — \($0.title)" } ?? "κανένα")
        """
    }

    private func renderRunReport(_ report: AutonomousRunReport) -> String {
        """
        AUTONOMOUS RUN STOPPED

        TASK
        \(report.taskId.uuidString)

        STOP REASON
        \(report.stopReason.rawValue)

        STEPS ATTEMPTED THIS CYCLE
        \(report.stepsAttempted)

        PROGRESS
        \(Int(report.progress * 100))%

        LAST CHECKPOINT
        \(report.lastCheckpoint ?? "κανένα")

        NEXT RUNNABLE STEP
        \(report.nextStepTitle ?? "κανένα")
        """
    }
}

private enum RuntimeIntegrationControlError: LocalizedError {
    case taskNotFound
    var errorDescription: String? { "Το runtime task δεν βρέθηκε μετά την εκτέλεση." }
}
