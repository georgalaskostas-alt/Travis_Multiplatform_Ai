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

            // startMission creates the durable task before it asks the planner
            // for an execution plan. Make that lifecycle visible immediately
            // instead of leaving the remote task looking silently PENDING at 0%.
            if let taskId = engine.activeTaskId,
               let task = self.taskRuntime.task(id: taskId),
               task.status == .pending,
               task.plan.steps.isEmpty {
                self.taskRuntime.markPlanning(taskId: taskId, message: message)
            }

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
                let reason = error.localizedDescription

                // Previously AutonomousMissionEngineV2 attempted runtime.pause()
                // when planning failed. pause() intentionally ignores pending/
                // planning tasks, so the durable task could remain stuck forever
                // as PENDING 0%. Persist the real failure explicitly instead.
                if let taskId = engine.activeTaskId {
                    self.taskRuntime.failTask(
                        taskId: taskId,
                        reason: "Mission planning/execution failed: \(reason)"
                    )
                }

                let message = "Autonomous Mission V2 failed: \(reason)"
                self.lastResponseSummary = message
                self.addAssistantMessage(message)
            }
        }
    }
}
