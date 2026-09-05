import Foundation

@MainActor
extension TRAVISAppState {
    func runAutonomousMissionV2(goal: String) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        isProcessing = true; isBusy = true; lastResponseSummary = "Starting autonomous mission…"
        let recentHistory = Array(chatMessages.suffix(8))
        let engine = AutonomousMissionEngineV2(runtime: taskRuntime, executor: taskExecutor, orchestrator: orchestrator)
        engine.onProgress = { [weak self] message in
            guard let self else { return }
            if let taskId = engine.activeTaskId, let task = self.taskRuntime.task(id: taskId), task.status == .pending, task.plan.steps.isEmpty { self.taskRuntime.markPlanning(taskId: taskId, message: message) }
            self.lastResponseSummary = message; self.addAssistantMessage(message)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false; self.isBusy = false }
            do {
                let report = try await engine.startMission(goal: trimmedGoal, recentHistory: recentHistory)
                self.lastResponseSummary = report.message
                let mode = report.state == .handedOff ? "ALWAYS-ON HEADLESS" : "MISSION V2"
                self.addAssistantMessage("""
                AUTONOMOUS MISSION V2

                TASK ID
                \(report.taskId.uuidString)

                EXECUTION MODE
                \(mode)

                STATE
                \(report.state.rawValue)

                PROGRESS
                \(Int(report.progress * 100))%

                PLAN VERSION
                \(report.planVersion)

                REPLANS USED
                \(report.replansUsed)

                \(report.message)
                """)
            } catch {
                let reason = error.localizedDescription
                if let taskId = engine.activeTaskId { self.taskRuntime.failTask(taskId: taskId, reason: "Mission planning/execution failed: \(reason)") }
                let message = "Autonomous Mission V2 failed: \(reason)"; self.lastResponseSummary = message; self.addAssistantMessage(message)
            }
        }
    }
}
