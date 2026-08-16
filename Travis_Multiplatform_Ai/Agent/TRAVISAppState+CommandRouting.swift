import Foundation

@MainActor
extension TRAVISAppState {
    private static var commandContextWindow: Int { 8 }

    func sendCommand(_ text: String, source: CommandSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendMessage(role: .user, text: trimmed)

        let recentHistory = Array(
            chatMessages
                .dropLast()
                .suffix(Self.commandContextWindow)
        )

        if trimmed.lowercased().hasPrefix("/plan ") {
            let goal = String(trimmed.dropFirst("/plan ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty else {
                addAssistantMessage("Χρήση: /plan <στόχος>")
                return
            }
            createAutonomousPlan(goal: goal)
            return
        }

        isProcessing = true
        Task {
            defer { isProcessing = false }

            if await handleSystemIntent(trimmed, recentHistory: recentHistory) {
                return
            }

            let command = TravisCommand(
                text: trimmed,
                source: source,
                status: .awaitingApproval
            )
            pendingCommands.append(command)
            lastResponseSummary = "Εντολή σε αναμονή: \(trimmed)"

            await orchestrator.route(
                trimmed,
                liveSessionId: currentSessionId,
                recentHistory: recentHistory
            )
        }
    }

    private func createAutonomousPlan(goal: String) {
        isProcessing = true
        lastResponseSummary = "Δημιουργία autonomous task…"

        Task {
            defer { isProcessing = false }
            do {
                let capabilityIds = orchestrator.capabilities.map(\.id)
                let plan = try await TaskPlanner.shared.makePlan(
                    for: goal,
                    availableCapabilities: capabilityIds
                )

                let createdTask = taskRuntime.createTask(
                    goal: goal,
                    priority: .medium
                )
                taskRuntime.attachPlan(taskId: createdTask.id, plan: plan)
                taskRuntime.start(taskId: createdTask.id)

                guard let runtimeTask = taskRuntime.task(id: createdTask.id) else {
                    throw CommandRoutingError.taskNotFound
                }

                let renderedSteps = runtimeTask.plan.steps
                    .sorted { $0.order < $1.order }
                    .map { step in
                        let dependencies = step.dependencyStepIds.isEmpty
                            ? ""
                            : " [dependencies: \(step.dependencyStepIds.count)]"
                        let capability = step.capabilityId.map { " → \($0)" } ?? ""
                        let approval = step.requiresApproval ? " 🔐" : ""
                        let background = step.canRunInBackground ? " ⚙️" : ""
                        return "\(step.order). \(step.title)\(capability)\(dependencies)\(approval)\(background)"
                    }
                    .joined(separator: "\n")

                let nextStepText: String
                if let next = taskRuntime.nextRunnableStep(taskId: runtimeTask.id) {
                    nextStepText = """
                    NEXT RUNNABLE STEP
                    #\(next.order) — \(next.title)

                    Risk: \(next.riskLevel.rawValue)
                    Approval required: \(next.requiresApproval ? "YES" : "NO")
                    Background eligible: \(next.canRunInBackground ? "YES" : "NO")
                    Capability: \(next.capabilityId ?? "unassigned")
                    """
                } else {
                    nextStepText = "NEXT RUNNABLE STEP\nNone currently available."
                }

                addAssistantMessage("""
                AUTONOMOUS TASK CREATED

                TASK ID
                \(runtimeTask.id.uuidString)

                STATUS
                \(runtimeTask.status.rawValue)

                PLAN v\(runtimeTask.plan.version)
                \(runtimeTask.plan.summary)

                \(renderedSteps)

                \(nextStepText)
                """)

                lastResponseSummary = "Task running — \(runtimeTask.plan.steps.count) steps"
            } catch {
                let message = "Runtime planning error: \(error.localizedDescription)"
                addAssistantMessage(message)
                lastResponseSummary = message
            }
        }
    }
}

private enum CommandRoutingError: LocalizedError {
    case taskNotFound
    var errorDescription: String? { "Το runtime task δεν βρέθηκε μετά τη δημιουργία του." }
}
