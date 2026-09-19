import Foundation

enum TaskPlannerError: LocalizedError {
    case emptyGoal
    case invalidStructuredResponse
    case noSteps
    case tooManySteps(Int)
    case invalidDependency(step: Int, dependency: Int)

    var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "Το task δεν έχει στόχο."
        case .invalidStructuredResponse:
            return "Ο planner επέστρεψε μη έγκυρο structured plan."
        case .noSteps:
            return "Ο planner δεν δημιούργησε κανένα βήμα."
        case .tooManySteps(let count):
            return "Ο planner δημιούργησε υπερβολικά πολλά βήματα (\(count))."
        case .invalidDependency(let step, let dependency):
            return "Μη έγκυρη dependency: step \(step) -> \(dependency)."
        }
    }
}

/// AI-backed planner for long-lived TRAVIS tasks.
///
/// The LLM proposes the plan. TRAVIS then validates and normalizes it before
/// anything can execute. Repository-grounded plans receive deterministic
/// capability routing, dependency repair, and scope-bounded success criteria.
final class TaskPlanner {
    static let shared = TaskPlanner()

    private let aiService: AIService
    private let maxPlanSteps = 16

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func makePlan(
        for goal: String,
        availableCapabilities: [String] = [],
        context: String? = nil
    ) async throws -> TaskPlan {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { throw TaskPlannerError.emptyGoal }

        let prompt = buildPrompt(
            goal: trimmedGoal,
            availableCapabilities: availableCapabilities,
            context: context
        )

        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 8192)
        let proposal = try decodeProposal(from: raw)

        return try materialize(
            proposal,
            goal: trimmedGoal,
            availableCapabilities: availableCapabilities
        )
    }

    // MARK: - Prompt

    private func buildPrompt(
        goal: String,
        availableCapabilities: [String],
        context: String?
    ) -> String {
        let capabilityText = availableCapabilities.isEmpty
            ? "No capability registry was supplied. Use null for capabilityId unless clearly known."
            : availableCapabilities.joined(separator: ", ")

        return """
        You are the planning component of TRAVIS, a persistent autonomous personal AI assistant.

        Your responsibility is PLANNING, not performing the task.

        USER GOAL:
        \(goal)

        AVAILABLE CAPABILITY IDS:
        \(capabilityText)

        OPTIONAL CONTEXT:
        \(context ?? "None")

        Create a robust execution plan. Decompose only as much as necessary.

        Keep the plan concise.
        The plan is an execution map, not the execution itself.
        Do not perform the analysis inside the plan.
        Do not write reports, conclusions, research findings, or implementation details inside the plan.
        Keep each title under 12 words.
        Keep each instructions field under 80 words.
        Use no more than \(maxPlanSteps) steps.
        Prefer high-value execution stages over many microscopic steps.

        For complex goals, create high-level stages.
        A future execution stage may create its own sub-plan when needed.
        Do not try to anticipate every possible subtask up-front.

        Steps may depend only on earlier steps.
        Include verification when the result could be wrong.
        Include explicit approval boundaries for consequential actions.
        Never claim that an action has already happened.

        Never invent capabilities that are not present in AVAILABLE CAPABILITY IDS.
        If no available capability clearly matches a step, use null for capabilityId.

        When repository_context is present in AVAILABLE CAPABILITY IDS:
        - repository inspection must use repository_context
        - source-code analysis must use repository_context
        - architecture/runtime/codebase review must use repository_context
        - synthesis of repository findings must use repository_context
        - evidence verification must use repository_context
        - final reports whose claims depend on source evidence must use repository_context
        - do NOT route repository-grounded synthesis/report/verification through text_task
        - each inspection step MUST have success criteria limited to that step's explicit scope
        - NEVER require repository-wide completeness in a narrow inspection step
        - NEVER make tests/docs/generated-artifact classification a criterion unless that exact step is dedicated to repository classification
        - limitations outside the loaded evidence scope are acceptable and must not automatically make an inspection step fail
        - source evidence is sufficient when it identifies the source file plus a concrete symbol, control-flow branch, state transition, API call, or data-flow behavior
        - exact line numbers or line ranges are OPTIONAL provenance metadata, not a success requirement, unless the user's goal or that exact step explicitly asks for line-level citations
        - NEVER add a line-number requirement merely because the task asks for "source evidence", "code evidence", "real evidence", or "specific evidence"

        Use text_task only for reasoning or writing whose correctness does not depend on repository evidence.

        Return ONLY valid JSON. No markdown fences or commentary.

        Schema:
        {
          "summary": "short plan summary",
          "steps": [
            {
              "order": 1,
              "title": "short action title",
              "instructions": "precise execution instructions",
              "capabilityId": null,
              "dependsOn": [],
              "successCriteria": ["observable condition"],
              "risk": "low",
              "requiresApproval": false,
              "canRunInBackground": true,
              "estimatedEffort": "short"
            }
          ]
        }

        Constraints:
        - order must be contiguous integers starting at 1
        - dependsOn contains step order numbers, never UUIDs
        - a step may depend only on a lower order number
        - risk must be exactly one of: low, medium, high, critical
        - estimatedEffort must be exactly one of: short, medium, long
        - use between 5 and \(maxPlanSteps) steps unless the goal genuinely requires fewer
        - avoid duplicate or overlapping steps
        - avoid splitting one logical stage into many tiny steps
        - every step must have at least one observable success criterion
        - verification should normally be a separate step for important outputs
        - synthesis/report/verification steps must depend on every earlier evidence-producing stage they require

        Approval rules:
        - destructive actions require approval
        - financial actions require approval
        - external sending or publishing requires approval
        - production deployment requires approval
        - credential changes require approval
        - permission changes require approval
        - irreversible actions require approval
        - self-modification affecting safety or permissions requires approval

        Research, analysis, reading, planning, local reasoning,
        non-destructive inspection and verification should normally not require approval.

        Background execution:
        - analysis and research may normally run in background
        - waiting, monitoring and long-running investigation may run in background
        - actions waiting for user approval cannot proceed until approval exists

        The final output must be syntactically complete JSON.
        """
    }

    // MARK: - Decode

    private func decodeProposal(from raw: String) throws -> PlannerProposal {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingMarkdownJSONFence()

        guard let data = cleaned.data(using: .utf8) else {
            throw TaskPlannerError.invalidStructuredResponse
        }

        do {
            return try JSONDecoder().decode(PlannerProposal.self, from: data)
        } catch {
            print("========== TRAVIS PLANNER RAW RESPONSE ==========")
            print(raw)
            print("========== TRAVIS PLANNER CLEANED RESPONSE ======")
            print(cleaned)
            print("========== TRAVIS PLANNER DECODE ERROR ==========")
            print(error)
            print("=================================================")
            throw TaskPlannerError.invalidStructuredResponse
        }
    }

    // MARK: - Validation + Deterministic Normalization

    private func materialize(
        _ proposal: PlannerProposal,
        goal: String,
        availableCapabilities: [String]
    ) throws -> TaskPlan {
        guard !proposal.steps.isEmpty else { throw TaskPlannerError.noSteps }
        guard proposal.steps.count <= maxPlanSteps else {
            throw TaskPlannerError.tooManySteps(proposal.steps.count)
        }

        let sorted = proposal.steps.sorted { $0.order < $1.order }
        guard sorted.map(\.order) == Array(1...sorted.count) else {
            throw TaskPlannerError.invalidStructuredResponse
        }

        let capabilitySet = Set(availableCapabilities)
        let repositoryGroundedPlan = capabilitySet.contains("repository_context") && isRepositoryGroundedGoal(goal)

        var idsByOrder: [Int: UUID] = [:]
        for step in sorted { idsByOrder[step.order] = UUID() }

        let steps: [PlanStep] = try sorted.map { proposalStep in
            var dependencyOrders = proposalStep.dependsOn

            if repositoryGroundedPlan && isAggregationOrVerificationStep(proposalStep) {
                dependencyOrders = Array(1..<proposalStep.order)
            }

            dependencyOrders = Array(Set(dependencyOrders)).sorted()

            for dependency in dependencyOrders {
                guard dependency > 0,
                      dependency < proposalStep.order,
                      idsByOrder[dependency] != nil
                else {
                    throw TaskPlannerError.invalidDependency(step: proposalStep.order, dependency: dependency)
                }
            }

            guard !proposalStep.successCriteria.isEmpty,
                  let stepID = idsByOrder[proposalStep.order]
            else { throw TaskPlannerError.invalidStructuredResponse }

            let capabilityId = normalizedCapabilityId(
                proposed: proposalStep.capabilityId,
                repositoryGroundedPlan: repositoryGroundedPlan,
                availableCapabilities: capabilitySet
            )

            let successCriteria = normalizedSuccessCriteria(
                proposalStep,
                capabilityId: capabilityId,
                repositoryGroundedPlan: repositoryGroundedPlan
            )

            return PlanStep(
                id: stepID,
                order: proposalStep.order,
                title: proposalStep.title,
                instructions: proposalStep.instructions,
                status: .pending,
                capabilityId: capabilityId,
                dependencyStepIds: dependencyOrders.compactMap { idsByOrder[$0] },
                successCriteria: successCriteria,
                riskLevel: PlanStepRiskLevel(rawValue: proposalStep.risk.rawValue) ?? .low,
                requiresApproval: proposalStep.requiresApproval,
                canRunInBackground: proposalStep.canRunInBackground,
                estimatedEffort: PlanStepEffort(rawValue: proposalStep.estimatedEffort.rawValue) ?? .short,
                maxAttempts: 3
            )
        }

        return TaskPlan(summary: proposal.summary, steps: steps)
    }

    private func normalizedSuccessCriteria(
        _ step: PlannerStepProposal,
        capabilityId: String?,
        repositoryGroundedPlan: Bool
    ) -> [String] {
        guard repositoryGroundedPlan, capabilityId == "repository_context" else {
            return step.successCriteria
        }

        let evidenceContract = "Source evidence may be identified by source path plus concrete symbol/control-flow/state/data-flow behavior; exact line numbers are not required unless this step explicitly requests line-level citations."

        if isAggregationOrVerificationStep(step) {
            return [
                "The result synthesizes only verified dependency and repository evidence relevant to this step.",
                "Claims without sufficient source evidence are explicitly marked as limitations rather than asserted as facts.",
                evidenceContract
            ]
        }

        return [
            "The result provides concrete source-level evidence for the specific scope described by this step title and instructions.",
            "The result does not claim repository-wide completeness beyond this step's loaded evidence scope; out-of-scope gaps are stated as limitations.",
            evidenceContract
        ]
    }

    private func normalizedCapabilityId(
        proposed: String?,
        repositoryGroundedPlan: Bool,
        availableCapabilities: Set<String>
    ) -> String? {
        guard repositoryGroundedPlan else { return proposed }

        if proposed == nil || proposed == "text_task" || proposed == "repository_context" {
            return availableCapabilities.contains("repository_context") ? "repository_context" : proposed
        }

        return proposed
    }

    private func isRepositoryGroundedGoal(_ goal: String) -> Bool {
        let value = goal.lowercased()
        let markers = [
            "repository", "repo", "codebase", "source code", "source files",
            "κώδικ", "αρχιτεκτον", "architecture", "runtime", "project travis",
            "travis project"
        ]
        return markers.contains { value.contains($0) }
    }

    private func isAggregationOrVerificationStep(_ step: PlannerStepProposal) -> Bool {
        let value = (step.title + " " + step.instructions).lowercased()
        let markers = [
            "synth", "consolidat", "report", "roadmap", "priorit",
            "verify", "verification", "evidence", "finding", "remediation",
            "σύνοψ", "αναφορά", "επαλήθευσ"
        ]
        return markers.contains { value.contains($0) }
    }
}

private struct PlannerProposal: Decodable {
    let summary: String
    let steps: [PlannerStepProposal]
}

private struct PlannerStepProposal: Decodable {
    let order: Int
    let title: String
    let instructions: String
    let capabilityId: String?
    let dependsOn: [Int]
    let successCriteria: [String]
    let risk: PlannerRisk
    let requiresApproval: Bool
    let canRunInBackground: Bool
    let estimatedEffort: PlannerEffort
}

private enum PlannerRisk: String, Codable { case low, medium, high, critical }
private enum PlannerEffort: String, Codable { case short, medium, long }

private extension String {
    func removingMarkdownJSONFence() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json") {
            value.removeFirst("```json".count)
        } else if value.hasPrefix("```") {
            value.removeFirst(3)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("```") { value.removeLast(3) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
