import Foundation

struct MissionPlannerV2StepDraft: Codable, Hashable {
    var order: Int
    var title: String
    var instructions: String
    var capabilityId: String
    var dependencyOrders: [Int]
    var successCriteria: [String]
    var riskLevel: PlanStepRiskLevel
    var canRunInBackground: Bool
    var estimatedEffort: PlanStepEffort
    var maxAttempts: Int
}

struct MissionPlannerV2Draft: Codable, Hashable {
    var summary: String
    var steps: [MissionPlannerV2StepDraft]
}

enum AutonomousMissionPlannerV2Error: LocalizedError {
    case emptyGoal
    case noCapabilities
    case malformedPlan(String)
    case invalidCapability(String)
    case duplicateOrder(Int)
    case missingDependency(step: Int, dependency: Int)

    var errorDescription: String? {
        switch self {
        case .emptyGoal: return "Ο στόχος της αποστολής είναι κενός."
        case .noCapabilities: return "Δεν υπάρχουν διαθέσιμα εργαλεία για να σχεδιαστεί η αποστολή."
        case .malformedPlan(let detail): return "Ο planner επέστρεψε μη έγκυρο σχέδιο: \(detail)"
        case .invalidCapability(let id): return "Ο planner επέλεξε άγνωστο εργαλείο: \(id)"
        case .duplicateOrder(let order): return "Το σχέδιο έχει διπλό αριθμό βήματος: \(order)"
        case .missingDependency(let step, let dependency): return "Το βήμα \(step) εξαρτάται από ανύπαρκτο βήμα \(dependency)."
        }
    }
}

@MainActor
final class AutonomousMissionPlannerV2 {
    private let aiService: AIService
    private let maxDecodeAttempts = 2

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func makePlan(
        goal: String,
        capabilities: [AgentCapability],
        priorKnowledge: String? = nil
    ) async throws -> TaskPlan {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { throw AutonomousMissionPlannerV2Error.emptyGoal }
        guard !capabilities.isEmpty else { throw AutonomousMissionPlannerV2Error.noCapabilities }

        let capabilityCatalog = capabilities.map { capability in
            "- \(capability.id): \(capability.name) — \(capability.capabilityDescription)"
        }.joined(separator: "\n")

        let knowledge = priorKnowledge?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        You are TRAVIS Mission Planner V2.

        Turn the user's goal into the smallest reliable execution plan that can finish the goal end-to-end.
        Do not merely describe work. Every step must be executable by exactly one available capability.

        USER GOAL:
        \(goal)

        AVAILABLE CAPABILITIES:
        \(capabilityCatalog)

        PRIOR VERIFIED KNOWLEDGE / EXPERIENCE:
        \(knowledge?.isEmpty == false ? knowledge! : "None")

        RULES:
        - Prefer 3-12 steps. Use more only when truly necessary.
        - Each step must have one capabilityId from AVAILABLE CAPABILITIES exactly as written.
        - Dependencies use earlier step order numbers only.
        - Success criteria must be concrete and verifiable.
        - Separate inspection, modification, verification and delivery when the goal requires them.
        - If code is changed, include a later verification/build/test step when an available capability can perform it.
        - If research is required, include source/evidence criteria.
        - Do not ask the user for information that can be discovered with available capabilities.
        - Risk must be low, medium, high or critical.
        - estimatedEffort must be short, medium or long.
        - maxAttempts must be 1...5.
        - Output JSON only. No Markdown.

        JSON SCHEMA:
        {
          "summary": "short execution strategy",
          "steps": [
            {
              "order": 1,
              "title": "short title",
              "instructions": "exact work to perform",
              "capabilityId": "exact capability id",
              "dependencyOrders": [],
              "successCriteria": ["criterion 1"],
              "riskLevel": "low",
              "canRunInBackground": true,
              "estimatedEffort": "short",
              "maxAttempts": 3
            }
          ]
        }
        """

        let draft = try await requestDraft(prompt: prompt)
        return try materialize(draft: draft, allowedCapabilityIds: Set(capabilities.map(\.id)))
    }

    func makeRecoveryPlan(
        task: AgentTask,
        capabilities: [AgentCapability]
    ) async throws -> TaskPlan {
        let completed = task.plan.steps
            .filter { $0.status == .completed }
            .sorted { $0.order < $1.order }

        let completedEvidence = completed.map { step in
            let result = String((step.resultSummary ?? "No result summary").prefix(5000))
            return "STEP #\(step.order) — \(step.title)\nVERIFIED RESULT:\n\(result)"
        }.joined(separator: "\n\n")

        let failed = task.plan.steps.first { $0.status == .failed }
        let failureBlock = failed.map {
            "FAILED STEP #\($0.order) — \($0.title)\nERROR: \($0.lastError ?? task.failureReason ?? "Unknown")"
        } ?? "No single failed step is marked; failure: \(task.failureReason ?? "Unknown")"

        let capabilityCatalog = capabilities.map { capability in
            "- \(capability.id): \(capability.name) — \(capability.capabilityDescription)"
        }.joined(separator: "\n")

        let prompt = """
        You are TRAVIS Self-Correction Planner V2.

        The mission did not complete. Produce a RECOVERY PLAN only for the remaining work.
        Do not repeat completed verified work unless a new verification step genuinely needs to inspect it.

        ORIGINAL GOAL:
        \(task.goal)

        PREVIOUS PLAN SUMMARY:
        \(task.plan.summary)

        COMPLETED VERIFIED WORK:
        \(completedEvidence.isEmpty ? "None" : completedEvidence)

        FAILURE:
        \(failureBlock)

        AVAILABLE CAPABILITIES:
        \(capabilityCatalog)

        RULES:
        - Diagnose the failure and choose a materially better route, not the same failed wording.
        - Return only the remaining steps needed to finish the original goal.
        - dependencyOrders refer only to steps in THIS recovery plan.
        - Use exact capability IDs.
        - Success criteria must prove the step worked.
        - Prefer 1-8 recovery steps.
        - maxAttempts must be 1...5.
        - Output JSON only, using the same schema as the normal mission planner.
        """

        let recoveryDraft = try await requestDraft(prompt: prompt)
        let recovery = try materialize(draft: recoveryDraft, allowedCapabilityIds: Set(capabilities.map(\.id)))
        return TaskPlan(
            version: task.plan.version + 1,
            summary: "Recovery v\(task.plan.version + 1): \(recovery.summary)",
            steps: recovery.steps
        )
    }

    private func requestDraft(prompt: String) async throws -> MissionPlannerV2Draft {
        var lastRaw = ""
        var lastError = "unknown error"

        for attempt in 1...maxDecodeAttempts {
            try Task.checkCancellation()
            let request: String
            if attempt == 1 {
                request = prompt
            } else {
                request = """
                Repair this response into valid JSON matching the requested MissionPlannerV2 schema.
                Return JSON only. Do not add prose.

                MALFORMED RESPONSE:
                \(lastRaw)
                """
            }

            let raw = try await AIExecutionScope.$context.withValue(
                AIInvocationContext(workload: .complex, operation: "autonomous.mission.plan.v2")
            ) {
                try await aiService.generateText(prompt: request, maxTokens: attempt == 1 ? 5000 : 2500)
            }
            lastRaw = raw

            do {
                let json = extractJSONObject(from: raw)
                guard let data = json.data(using: .utf8) else {
                    throw AutonomousMissionPlannerV2Error.malformedPlan("response is not UTF-8")
                }
                return try JSONDecoder().decode(MissionPlannerV2Draft.self, from: data)
            } catch {
                lastError = error.localizedDescription
            }
        }

        throw AutonomousMissionPlannerV2Error.malformedPlan(lastError)
    }

    private func materialize(draft: MissionPlannerV2Draft, allowedCapabilityIds: Set<String>) throws -> TaskPlan {
        guard !draft.steps.isEmpty else {
            throw AutonomousMissionPlannerV2Error.malformedPlan("plan has no steps")
        }

        let sorted = draft.steps.sorted { $0.order < $1.order }
        var seenOrders = Set<Int>()
        for step in sorted {
            guard seenOrders.insert(step.order).inserted else {
                throw AutonomousMissionPlannerV2Error.duplicateOrder(step.order)
            }
            guard allowedCapabilityIds.contains(step.capabilityId) else {
                throw AutonomousMissionPlannerV2Error.invalidCapability(step.capabilityId)
            }
            guard (1...5).contains(step.maxAttempts) else {
                throw AutonomousMissionPlannerV2Error.malformedPlan("step \(step.order) maxAttempts must be 1...5")
            }
            for dependency in step.dependencyOrders {
                guard dependency < step.order, seenOrders.contains(dependency) else {
                    throw AutonomousMissionPlannerV2Error.missingDependency(step: step.order, dependency: dependency)
                }
            }
        }

        var idByOrder: [Int: UUID] = [:]
        for step in sorted { idByOrder[step.order] = UUID() }

        let steps = try sorted.map { draftStep -> PlanStep in
            let dependencies = try draftStep.dependencyOrders.map { order -> UUID in
                guard let id = idByOrder[order] else {
                    throw AutonomousMissionPlannerV2Error.missingDependency(step: draftStep.order, dependency: order)
                }
                return id
            }
            return PlanStep(
                id: idByOrder[draftStep.order]!,
                order: draftStep.order,
                title: draftStep.title,
                instructions: draftStep.instructions,
                capabilityId: draftStep.capabilityId,
                dependencyStepIds: dependencies,
                successCriteria: draftStep.successCriteria,
                riskLevel: draftStep.riskLevel,
                canRunInBackground: draftStep.canRunInBackground,
                estimatedEffort: draftStep.estimatedEffort,
                maxAttempts: draftStep.maxAttempts
            )
        }

        return TaskPlan(
            version: 1,
            summary: draft.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps
        )
    }

    private func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let withoutFence = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = withoutFence.firstIndex(of: "{"), let last = withoutFence.lastIndex(of: "}") {
                return String(withoutFence[first...last])
            }
            return withoutFence
        }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            return String(trimmed[first...last])
        }
        return trimmed
    }
}
