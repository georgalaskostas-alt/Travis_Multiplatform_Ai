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
            createAutonomousPlan(goal: goal, projectId: nil)
            return
        }

        isProcessing = true
        Task {
            defer { isProcessing = false }

            if await handleSystemIntent(trimmed, recentHistory: recentHistory) {
                return
            }

            let goalRouter = GoalIntentRouter()
            switch await goalRouter.classify(trimmed, recentHistory: recentHistory) {
            case .createProject(let title, let goal):
                let project = ProjectWorkspaceStore.shared.create(title: title, goal: goal)
                addAssistantMessage("""
                PROJECT WORKSPACE CREATED

                PROJECT
                \(project.title)

                ID
                \(project.id.uuidString)

                GOAL
                \(project.goal)

                Δημιουργώ τώρα το πρώτο autonomous execution plan για αυτό το project.
                """)
                createAutonomousPlan(goal: goal, projectId: project.id)
                return

            case .continueProject(let reference):
                let matches = ProjectWorkspaceStore.shared.find(reference)
                if matches.count == 1, let project = matches.first {
                    addAssistantMessage(renderProjectContext(project))
                    await orchestrator.route(
                        "Συνέχισε το project '\(project.title)'. Project goal: \(project.goal). Current summary: \(project.summary). User request: \(trimmed)",
                        liveSessionId: currentSessionId,
                        recentHistory: recentHistory
                    )
                    return
                }
                if matches.count > 1 {
                    let rows = matches.prefix(8).map { "\($0.id.uuidString.prefix(8)) — \($0.title)" }.joined(separator: "\n")
                    addAssistantMessage("Βρήκα περισσότερα από ένα projects:\n\n\(rows)\n\nΔώσε πιο συγκεκριμένη αναφορά.")
                    return
                }

            case .listProjects:
                addAssistantMessage(renderProjectList())
                return

            case .none:
                break
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

    func createAutonomousPlan(goal: String, projectId: UUID?) {
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

                if let projectId {
                    ProjectWorkspaceStore.shared.attachTask(createdTask.id, to: projectId)
                }

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

                let projectText = projectId.map { "\nPROJECT ID\n\($0.uuidString)\n" } ?? ""

                addAssistantMessage("""
                AUTONOMOUS TASK CREATED
                \(projectText)
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

    private func renderProjectList() -> String {
        let projects = ProjectWorkspaceStore.shared.load()
        guard !projects.isEmpty else { return "Δεν υπάρχουν αποθηκευμένα project workspaces." }
        let rows = projects.prefix(20).map {
            "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] tasks:\($0.taskIds.count) — \($0.title)"
        }.joined(separator: "\n")
        return "PROJECT WORKSPACES\n\n\(rows)"
    }

    private func renderProjectContext(_ project: ProjectWorkspace) -> String {
        """
        PROJECT CONTEXT

        \(project.title)
        ID: \(project.id.uuidString)
        Status: \(project.status.rawValue)
        Goal: \(project.goal)
        Tasks: \(project.taskIds.count)
        Decisions: \(project.decisions.count)
        Notes: \(project.notes.count)
        Artifacts: \(project.artifactPaths.count)
        """
    }
}

private enum CommandRoutingError: LocalizedError {
    case taskNotFound
    var errorDescription: String? { "Το runtime task δεν βρέθηκε μετά τη δημιουργία του." }
}
