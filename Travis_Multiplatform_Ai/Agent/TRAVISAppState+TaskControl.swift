import Foundation

@MainActor
extension TRAVISAppState {
    func resolveRuntimeTask(reference: String?) -> AgentTaskResolver.Resolution {
        AgentTaskResolver().resolve(reference, in: taskRuntime.tasks)
    }

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
        case .aiUsage:
            addAssistantMessage(AIUsageLedger.shared.diagnosticReport())
        case .aiModels:
            addAssistantMessage(AIModelPerformanceService().diagnosticReport())
        case .localIntelligence:
            addAssistantMessage(LocalIntelligenceMetrics.shared.diagnosticReport())
        case .trainingDataset:
            addAssistantMessage(TrainingDatasetPipeline.shared.diagnosticReport())
        case .trainingPolicy:
            addAssistantMessage(LocalModelTrainingPolicy.shared.diagnosticReport())
        case .localModelRegistry:
            addAssistantMessage(LocalModelRegistry.shared.diagnosticReport())
        case .trainingRuns:
            addAssistantMessage(LocalTrainingCoordinator.shared.diagnosticReport())
        case .trainingStart(let kindRaw, let name, let baseModel):
            await startLocalTraining(kindRaw: kindRaw, name: name, baseModel: baseModel)
        case .trainingRefresh(let reference):
            await refreshLocalTraining(reference: reference)
        case .trainingCancel(let reference):
            await cancelLocalTraining(reference: reference)
        case .trainingPromote(let candidateReference, let inferenceModelId):
            promoteLocalTrainingCandidate(reference: candidateReference, inferenceModelId: inferenceModelId)
        case .trainingRollback(let candidateReference, let reason):
            rollbackLocalTrainingCandidate(reference: candidateReference, reason: reason)
        }
        return true
    }

    func runAutonomousTask(reference: String?, continuous: Bool) {
        let action = continuous ? "auto" : "run"
        guard let task = resolvedTaskForMutation(reference, action: action) else { return }
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

                if taskRuntime.task(id: task.id)?.status == .completed {
                    await synchronizeCompletedTask(task.id)
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

            for taskId in report.executedTaskIds where taskRuntime.task(id: taskId)?.status == .completed {
                await synchronizeCompletedTask(taskId)
            }

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

            ORPHAN TASKS SAFELY PAUSED
            \(report.pausedOrphanTaskIds.count)
            """)
        }
    }

    private func startLocalTraining(kindRaw: String, name: String, baseModel: String) async {
        guard let kind = TrainingDatasetPipeline.DatasetKind(rawValue: kindRaw) else {
            addAssistantMessage("Άγνωστο dataset kind '\(kindRaw)'. Επιτρεπτά: \(TrainingDatasetPipeline.DatasetKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            return
        }
        do {
            let run = try await LocalTrainingCoordinator.shared.start(name: name, kind: kind, baseModel: baseModel)
            addAssistantMessage("LOCAL TRAINING STARTED\n\nRUN ID\n\(String(run.id.uuidString.prefix(8)))\n\nBACKEND JOB\n\(run.backendJobId)\n\nSTATE\n\(run.state.rawValue)")
        } catch {
            addAssistantMessage("Local training did not start: \(error.localizedDescription)")
        }
    }

    private func refreshLocalTraining(reference: String) async {
        guard let run = resolveTrainingRun(reference) else {
            addAssistantMessage("Δεν βρέθηκε local training run που να ταιριάζει με '\(reference)'.")
            return
        }
        do {
            guard let updated = try await LocalTrainingCoordinator.shared.refresh(runId: run.id) else { return }
            let progress = updated.progress.map { "\(Int(min(max($0, 0), 1) * 100))%" } ?? "unknown"
            addAssistantMessage("LOCAL TRAINING STATUS\n\nRUN\n\(String(updated.id.uuidString.prefix(8)))\n\nSTATE\n\(updated.state.rawValue)\n\nPROGRESS\n\(progress)\n\n\(LocalModelTrainingPolicy.shared.diagnosticReport())")
        } catch {
            addAssistantMessage("Local training refresh failed: \(error.localizedDescription)")
        }
    }

    private func cancelLocalTraining(reference: String) async {
        guard let run = resolveTrainingRun(reference) else {
            addAssistantMessage("Δεν βρέθηκε local training run που να ταιριάζει με '\(reference)'.")
            return
        }
        do {
            guard let updated = try await LocalTrainingCoordinator.shared.cancel(runId: run.id) else { return }
            addAssistantMessage("LOCAL TRAINING CANCELLED\n\nRUN\n\(String(updated.id.uuidString.prefix(8)))\n\nSTATE\n\(updated.state.rawValue)")
        } catch {
            addAssistantMessage("Local training cancellation failed: \(error.localizedDescription)")
        }
    }

    private func promoteLocalTrainingCandidate(reference: String, inferenceModelId: String) {
        guard let candidate = resolveTrainingCandidate(reference) else {
            addAssistantMessage("Δεν βρέθηκε training candidate που να ταιριάζει με '\(reference)'.")
            return
        }
        guard LocalModelTrainingPolicy.shared.promote(candidateId: candidate.id, inferenceModelId: inferenceModelId) else {
            addAssistantMessage("Ο candidate δεν είναι eligible για promotion. Πρέπει πρώτα να έχει stage=candidate και verified training artifact.")
            return
        }
        addAssistantMessage("LOCAL MODEL PROMOTED\n\nCANDIDATE\n\(String(candidate.id.uuidString.prefix(8))) — \(candidate.name)\n\nINFERENCE MODEL\n\(inferenceModelId)\n\n\(LocalModelRegistry.shared.diagnosticReport())")
    }

    private func rollbackLocalTrainingCandidate(reference: String, reason: String) {
        guard let candidate = resolveTrainingCandidate(reference) else {
            addAssistantMessage("Δεν βρέθηκε training candidate που να ταιριάζει με '\(reference)'.")
            return
        }
        LocalModelTrainingPolicy.shared.rollback(candidateId: candidate.id, reason: reason)
        addAssistantMessage("LOCAL MODEL ROLLBACK\n\nCANDIDATE\n\(String(candidate.id.uuidString.prefix(8))) — \(candidate.name)\n\nREASON\n\(reason)\n\n\(LocalModelRegistry.shared.diagnosticReport())")
    }

    private func resolveTrainingRun(_ reference: String) -> LocalTrainingCoordinator.ActiveRun? {
        let normalized = reference.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = LocalTrainingCoordinator.shared.activeRuns.filter {
            $0.id.uuidString.lowercased().hasPrefix(normalized) ||
            $0.backendJobId.lowercased().contains(normalized)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveTrainingCandidate(_ reference: String) -> LocalModelTrainingPolicy.ModelCandidate? {
        let normalized = reference.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = LocalModelTrainingPolicy.shared.candidates.filter {
            $0.id.uuidString.lowercased().hasPrefix(normalized) ||
            $0.name.lowercased().contains(normalized)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func synchronizeCompletedTask(_ taskId: UUID) async {
        guard let completedTask = taskRuntime.task(id: taskId), completedTask.status == .completed else { return }

        await ProjectMemoryCoordinator().synchronize(taskId: taskId, runtime: taskRuntime)

        let projectId = ProjectWorkspaceStore.shared.project(containingTask: taskId)?.id
        VerifiedLearningStore.shared.ingestCompletedTask(completedTask, projectId: projectId)
        ReusableSkillStore.shared.ingestCompletedTask(completedTask)
        TrainingDatasetPipeline.shared.ingestCompletedTask(completedTask)
        SkillDistillationService.shared.refresh(
            skills: ReusableSkillStore.shared.skills,
            capabilities: orchestrator.capabilities
        )
    }

    private static var runtimeControlContextWindow: Int { 8 }

    private func command(_ base: String, _ reference: String?) -> String {
        guard let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base + " " + reference
    }

    private func resolvedTaskForMutation(_ reference: String?, action: String) -> AgentTask? {
        let effectiveReference: String?
        if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveReference = reference
        } else {
            switch action {
            case "run", "auto": effectiveReference = "running"
            case "resume": effectiveReference = "paused"
            case "retry": effectiveReference = "failed"
            case "cancel": effectiveReference = taskRuntime.tasks.contains(where: { $0.status == .running }) ? "running" : "paused"
            default: effectiveReference = nil
            }
        }

        switch resolveRuntimeTask(reference: effectiveReference) {
        case .found(let task): return task
        case .notFound:
            addAssistantMessage("Δεν βρέθηκε autonomous task για \(action). Χρησιμοποίησε /tasks.")
            return nil
        case .ambiguous(let tasks):
            let rows = tasks.prefix(8).map { "\(shortTaskId($0)) [\($0.status.rawValue)] — \($0.title)" }.joined(separator: "\n")
            addAssistantMessage("Βρήκα περισσότερα από ένα tasks. Δεν θα επιλέξω αυθαίρετα:\n\n\(rows)\n\nΔώσε το short ID ή πιο συγκεκριμένη αναφορά.")
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
