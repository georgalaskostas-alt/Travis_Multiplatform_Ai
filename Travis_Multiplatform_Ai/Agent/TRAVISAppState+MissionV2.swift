import Foundation

@MainActor
extension TRAVISAppState {
    /// Starts a durable autonomous mission and immediately executes it through
    /// AutonomousMissionEngineV2. This is the entry point used by remote/iPhone
    /// mission requests so they do not stop at RUNNING 0% after planning.
    func runAutonomousMissionV2(goal: String) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }

        isProcessing = true
        isBusy = true
        lastResponseSummary = "Starting autonomous mission…"

        let recentHistory = Array(chatMessages.suffix(8))
        let engine = AutonomousMissionEngineV2(
            runtime: taskRuntime,
            executor: taskExecutor,
            orchestrator: orchestrator
        )

        engine.onProgress = { [weak self] message in
            guard let self else { return }
            self.lastResponseSummary = message
            self.addAssistantMessage(message)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.isBusy = false
            }

            do {
                let report = try await engine.startMission(
                    goal: trimmedGoal,
                    recentHistory: recentHistory
                )

                self.lastResponseSummary = report.message
                self.addAssistantMessage("""
                AUTONOMOUS MISSION V2

                TASK ID
                \(report.taskId.uuidString)

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
                let message = "Autonomous Mission V2 failed: \(error.localizedDescription)"
                self.lastResponseSummary = message
                self.addAssistantMessage(message)
            }
        }
    }
}
