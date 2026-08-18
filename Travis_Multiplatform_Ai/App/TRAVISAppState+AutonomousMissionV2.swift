import Foundation

@MainActor
extension TRAVISAppState {
    func runAutonomousMissionV2(goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addAssistantMessage("Δώσε μου έναν στόχο για την autonomous mission.")
            return
        }

        appendMessage(role: .user, text: trimmed)
        isBusy = true
        isProcessing = true
        currentDeviceState = .thinking
        lastResponseSummary = "Planning autonomous mission"

        let engine = makeMissionEngineV2()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false
                self.isProcessing = false
                self.currentDeviceState = self.isListening ? .listening : .idle
            }

            do {
                let report = try await engine.startMission(
                    goal: trimmed,
                    recentHistory: Array(self.chatMessages.suffix(24))
                )
                self.lastResponseSummary = report.message
                self.addAssistantMessage(self.renderMissionV2Report(report))
                await self.synchronizeMissionKnowledgeV2(taskId: report.taskId)
            } catch {
                self.lastResponseSummary = error.localizedDescription
                self.addAssistantMessage("Η autonomous mission δεν ολοκληρώθηκε: \(error.localizedDescription)")
            }
        }
    }

    func continueAutonomousMissionV2(taskId: UUID) {
        isBusy = true
        isProcessing = true
        currentDeviceState = .thinking
        lastResponseSummary = "Continuing autonomous mission"

        let engine = makeMissionEngineV2()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false
                self.isProcessing = false
                self.currentDeviceState = self.isListening ? .listening : .idle
            }

            do {
                let report = try await engine.continueMission(
                    taskId: taskId,
                    recentHistory: Array(self.chatMessages.suffix(24))
                )
                self.lastResponseSummary = report.message
                self.addAssistantMessage(self.renderMissionV2Report(report))
                await self.synchronizeMissionKnowledgeV2(taskId: report.taskId)
            } catch {
                self.lastResponseSummary = error.localizedDescription
                self.addAssistantMessage("Δεν μπόρεσα να συνεχίσω την mission: \(error.localizedDescription)")
            }
        }
    }

    private func makeMissionEngineV2() -> AutonomousMissionEngineV2 {
        let engine = AutonomousMissionEngineV2(
            runtime: taskRuntime,
            executor: taskExecutor,
            orchestrator: orchestrator
        )
        engine.onProgress = { [weak self] message in
            self?.lastResponseSummary = message
            self?.addAssistantMessage(message)
        }
        return engine
    }

    private func renderMissionV2Report(_ report: AutonomousMissionV2Report) -> String {
        let percent = Int(report.progress * 100)
        return """
        TRAVIS AUTONOMOUS MISSION V2

        Status: \(report.state.rawValue)
        Progress: \(percent)%
        Plan version: v\(report.planVersion)
        Automatic corrections: \(report.replansUsed)
        Task: \(report.taskId.uuidString.prefix(8))

        \(report.message)
        """
    }

    private func synchronizeMissionKnowledgeV2(taskId: UUID) async {
        guard let task = taskRuntime.task(id: taskId), task.status == .completed else { return }
        await ProjectMemoryCoordinator().synchronize(taskId: taskId, runtime: taskRuntime)
        TravisLearningService.shared.refresh()
    }
}
