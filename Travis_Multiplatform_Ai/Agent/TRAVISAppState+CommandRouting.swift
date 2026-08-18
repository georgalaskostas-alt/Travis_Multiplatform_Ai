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

        if trimmed.lowercased() == "/capabilities" {
            let registry = CapabilityRegistry(capabilities: orchestrator.capabilities)
            addAssistantMessage(registry.diagnosticReport())
            return
        }

        if trimmed.lowercased() == "/learning" {
            addAssistantMessage(VerifiedLearningStore.shared.diagnosticReport())
            return
        }

        if trimmed.lowercased() == "/skills" {
            addAssistantMessage(ReusableSkillStore.shared.diagnosticReport())
            return
        }

        if trimmed.lowercased() == "/distillation" {
            addAssistantMessage(SkillDistillationService.shared.diagnosticReport())
            return
        }

        if trimmed.lowercased().hasPrefix("/plan ") {
            let goal = String(trimmed.dropFirst("/plan ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty else {
                addAssistantMessage("Χρήση: /plan <στόχος>")
                return
            }
            createAutonomousPlan(goal: goal, projectId: boundProject()?.id)
            return
        }

        isProcessing = true
        Task {
            defer { isProcessing = false }

            if await handleSchedulingIntent(trimmed, recentHistory: recentHistory) {
                return
            }

            if await handleSystemIntent(trimmed, recentHistory: recentHistory) {
                return
            }

            // Exact local multi-step work is promoted directly to an autonomous
            // task. Batch workflows are checked first because they intentionally
            // operate on a verified set of files rather than a single document.
            if LocalBatchWorkflowIntentRouter.shared.plan(for: trimmed, capabilities: orchestrator.capabilities) != nil ||
                LocalWorkflowIntentRouter.shared.plan(for: trimmed, capabilities: orchestrator.capabilities) != nil {
                createAutonomousPlan(goal: trimmed, projectId: boundProject()?.id)
                return
            }

            let memoryRouter = ProjectMemoryIntentRouter()
            switch await memoryRouter.classify(trimmed, recentHistory: recentHistory) {
            case .addDecision(let reference, let text, let rationale):
                guard let project = resolveProjectForMemory(reference) else { return }
                bindCurrentSession(to: project)
                ProjectWorkspaceStore.shared.addDecision(text, rationale: rationale, to: project.id)
                addAssistantMessage("PROJECT DECISION SAVED\n\n\(project.title)\n\n\(text)")
                lastResponseSummary = "Project decision saved"
                return

            case .addNote(let reference, let text):
                guard let project = resolveProjectForMemory(reference) else { return }
                bindCurrentSession(to: project)
                ProjectWorkspaceStore.shared.addNote(text, to: project.id)
                addAssistantMessage("PROJECT NOTE SAVED\n\n\(project.title)\n\n\(text)")
                lastResponseSummary = "Project note saved"
                return

            case .showProject(let reference):
                guard let project = resolveProjectForMemory(reference) else { return }
                bindCurrentSession(to: project)
                addAssistantMessage(renderProjectContext(project, includeMemory: true))
                return

            case .continueLatest:
                guard let project = resolveProjectForMemory(nil) else { return }
                continueProject(project, userRequest: trimmed)
                return

            case .none:
                break
            }

            let goalRouter = GoalIntentRouter()
            switch await goalRouter.classify(trimmed, recentHistory: recentHistory) {
            case .createProject(let title, let goal):
                let project = ProjectWorkspaceStore.shared.create(title: title, goal: goal)
                bindCurrentSession(to: project)
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
                switch ProjectWorkspaceStore.shared.resolve(reference) {
                case .found(let project):
                    continueProject(project, userRequest: trimmed)
                    return
                case .ambiguous(let projects):
                    addAssistantMessage(renderProjectAmbiguity(projects))
                    return
                case .notFound:
                    addAssistantMessage("Δεν βρήκα project που να ταιριάζει με '\(reference)'. Γράψε /projects για τα διαθέσιμα workspaces.")
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

            let routedText = contextualizedConversationCommand(trimmed)
            await orchestrator.route(
                routedText,
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
                let planningGoal = enrichedGoal(goal, projectId: projectId)
                let registry = CapabilityRegistry(capabilities: orchestrator.capabilities)

                let batchWorkflowPlan = LocalBatchWorkflowIntentRouter.shared.plan(
                    for: goal,
                    capabilities: orchestrator.capabilities
                )
                let localWorkflowPlan = batchWorkflowPlan == nil
                    ? LocalWorkflowIntentRouter.shared.plan(
                        for: goal,
                        capabilities: orchestrator.capabilities
                    )
                    : nil
                let deterministicMatch = batchWorkflowPlan == nil && localWorkflowPlan == nil
                    ? SkillExecutionEngine.shared.deterministicPlan(
                        for: goal,
                        capabilities: orchestrator.capabilities
                    )
                    : nil

                let plan: TaskPlan
                let planningSource: String
                if let batchWorkflowPlan {
                    plan = batchWorkflowPlan
                    planningSource = "LOCAL BATCH WORKFLOW — exact verified file set, 0 planner tokens"
                } else if let localWorkflowPlan {
                    plan = localWorkflowPlan
                    planningSource = "LOCAL WORKFLOW — exact structured operations, 0 planner tokens"
                } else if let deterministicMatch {
                    plan = deterministicMatch.plan
                    planningSource = "LOCAL VERIFIED SKILL — similarity \(String(format: "%.2f", deterministicMatch.similarity)), observations \(deterministicMatch.skill.observationCount), 0 planner tokens"
                } else {
                    let skillContext = ReusableSkillStore.shared.planningContext(for: planningGoal)
                    let plannerContext = [registry.promptCatalog(), skillContext]
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n\n")

                    plan = try await TaskPlanner.shared.makePlan(
                        for: planningGoal,
                        availableCapabilities: registry.ids,
                        context: plannerContext
                    )
                    planningSource = "CLOUD/AI PLANNER"
                }

                let createdTask = taskRuntime.createTask(
                    goal: planningGoal,
                    title: projectId.flatMap { ProjectWorkspaceStore.shared.project(id: $0)?.title },
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

                PLANNING SOURCE
                \(planningSource)

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

    private func continueProject(_ project: ProjectWorkspace, userRequest: String) {
        bindCurrentSession(to: project)
        let memory = ProjectWorkspaceStore.shared.contextBlock(for: project, taskRuntime: taskRuntime)
        addAssistantMessage("""
        PROJECT CONTEXT LOADED

        \(project.title)
        \(String(project.id.uuidString.prefix(8)))

        Δημιουργώ νέο autonomous task μέσα στο ίδιο project και συνεχίζω από το αποθηκευμένο context.
        """)

        let continuationGoal = """
        Continue this existing project from its canonical persisted state.

        \(memory)

        CURRENT USER REQUEST
        \(userRequest)

        Preserve established project decisions and constraints. Do not restart the project from scratch. Produce only the next useful body of work required by the current request.
        """
        createAutonomousPlan(goal: continuationGoal, projectId: project.id)
    }

    private func enrichedGoal(_ goal: String, projectId: UUID?) -> String {
        guard let projectId,
              let memory = ProjectWorkspaceStore.shared.contextBlock(for: projectId, taskRuntime: taskRuntime) else {
            return goal
        }
        return """
        \(goal)

        \(memory)

        PROJECT CONTINUITY RULES
        - Treat project memory above as canonical unless the user explicitly changes a decision.
        - Do not discard prior verified work.
        - Prefer extending existing artifacts/tasks over recreating them.
        - If current evidence conflicts with project memory, surface the conflict explicitly instead of silently overwriting memory.
        """
    }

    private func contextualizedConversationCommand(_ command: String) -> String {
        guard let project = boundProject() else { return command }
        let memory = ProjectWorkspaceStore.shared.contextBlock(for: project, taskRuntime: taskRuntime)
        return """
        The user is currently working inside a persistent TRAVIS project workspace.
        Use the project memory as context, but answer/act on the CURRENT USER MESSAGE rather than restarting the project.

        \(memory)

        CURRENT USER MESSAGE
        \(command)
        """
    }

    private func boundProject() -> ProjectWorkspace? {
        ProjectSessionBindingStore.shared.project(for: currentSessionId)
    }

    private func bindCurrentSession(to project: ProjectWorkspace) {
        ProjectSessionBindingStore.shared.bind(sessionId: currentSessionId, projectId: project.id)
    }

    private func resolveProjectForMemory(_ reference: String?) -> ProjectWorkspace? {
        if reference == nil, let bound = boundProject() {
            return bound
        }

        switch ProjectWorkspaceStore.shared.resolve(reference) {
        case .found(let project):
            return project
        case .ambiguous(let projects):
            addAssistantMessage(renderProjectAmbiguity(projects))
            return nil
        case .notFound:
            addAssistantMessage("Δεν βρέθηκε project workspace. Δημιούργησε πρώτα ένα project ή γράψε /projects.")
            return nil
        }
    }

    private func renderProjectList() -> String {
        let projects = ProjectWorkspaceStore.shared.load()
        guard !projects.isEmpty else { return "Δεν υπάρχουν αποθηκευμένα project workspaces." }
        let rows = projects.prefix(20).map {
            "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] tasks:\($0.taskIds.count) decisions:\($0.decisions.count) notes:\($0.notes.count) — \($0.title)"
        }.joined(separator: "\n")
        return "PROJECT WORKSPACES\n\n\(rows)"
    }

    private func renderProjectContext(_ project: ProjectWorkspace, includeMemory: Bool = false) -> String {
        if includeMemory {
            return ProjectWorkspaceStore.shared.contextBlock(for: project, taskRuntime: taskRuntime)
        }
        return """
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

    private func renderProjectAmbiguity(_ projects: [ProjectWorkspace]) -> String {
        let rows = projects.prefix(8).map {
            "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] — \($0.title)"
        }.joined(separator: "\n")
        return "Βρήκα περισσότερα από ένα projects. Δεν θα επιλέξω αυθαίρετα:\n\n\(rows)\n\nΔώσε short ID ή πιο συγκεκριμένο όνομα."
    }
}

private enum CommandRoutingError: LocalizedError {
    case taskNotFound
    var errorDescription: String? { "Το runtime task δεν βρέθηκε μετά τη δημιουργία του." }
}
