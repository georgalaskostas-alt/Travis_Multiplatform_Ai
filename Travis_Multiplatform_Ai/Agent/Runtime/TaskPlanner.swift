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
/// The LLM proposes the plan.
/// TRAVIS validates and normalizes it before anything can be executed.
///
/// The planner:
/// - does NOT execute tools
/// - does NOT grant permissions
/// - does NOT trust model-generated UUIDs
/// - validates dependencies
/// - limits plan complexity
/// - creates internal UUIDs for execution steps
/// - materializes planner metadata into typed PlanStep fields
final class TaskPlanner {

    static let shared = TaskPlanner()

    private let aiService: AIService

    /// Keep top-level plans intentionally compact.
    ///
    /// Complex work should later be decomposed into sub-plans
    /// when execution reaches that stage, instead of generating
    /// enormous plans up-front.
    private let maxPlanSteps = 16

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    // MARK: - Public API

    func makePlan(
        for goal: String,
        availableCapabilities: [String] = [],
        context: String? = nil
    ) async throws -> TaskPlan {

        let trimmedGoal = goal
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedGoal.isEmpty else {
            throw TaskPlannerError.emptyGoal
        }

        let prompt = buildPrompt(
            goal: trimmedGoal,
            availableCapabilities: availableCapabilities,
            context: context
        )

        // Planner responses can be larger than normal conversational replies.
        // 8192 gives enough room for a robust structured plan,
        // while the prompt itself prevents unnecessary plan explosion.
        let raw = try await aiService.generateText(
            prompt: prompt,
            maxTokens: 8192
        )

        let proposal = try decodeProposal(from: raw)

        return try materialize(proposal)
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
        When repository_context is present in AVAILABLE CAPABILITY IDS, assign repository inspection,
        source-code analysis, architecture review, runtime/codebase investigation, implementation review,
        and any task whose correctness depends on the actual TRAVIS source tree to repository_context.
        Do not assign those source-grounded tasks to text_task when repository_context is available.
        Use text_task for reasoning or writing that does not require repository evidence.

        Return ONLY valid JSON.
        Do not use markdown fences.
        Do not include explanations before or after the JSON.

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
              "successCriteria": [
                "observable condition"
              ],
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
        - risk must be exactly one of:
          low, medium, high, critical
        - estimatedEffort must be exactly one of:
          short, medium, long
        - use between 5 and \(maxPlanSteps) steps unless the goal genuinely requires fewer
        - avoid duplicate or overlapping steps
        - avoid splitting one logical stage into many tiny steps
        - every step must have at least one observable success criterion
        - verification should normally be a separate step for important outputs

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
        non-destructive inspection and verification should normally
        not require approval.

        Background execution:

        - analysis and research may normally run in background
        - waiting, monitoring and long-running investigation may run in background
        - actions waiting for user approval cannot proceed until approval exists

        The final output must be syntactically complete JSON.
        Ensure all braces, arrays and strings are properly closed before responding.
        """
    }

    // MARK: - Decode

    private func decodeProposal(
        from raw: String
    ) throws -> PlannerProposal {

        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingMarkdownJSONFence()

        guard let data = cleaned.data(using: .utf8) else {
            throw TaskPlannerError.invalidStructuredResponse
        }

        do {
            return try JSONDecoder().decode(
                PlannerProposal.self,
                from: data
            )
        } catch {

            // TEMPORARY diagnostic logging.
            //
            // Remove this before production because planner responses
            // may eventually contain sensitive/private user context.

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

    // MARK: - Validation + Materialization

    private func materialize(
        _ proposal: PlannerProposal
    ) throws -> TaskPlan {

        guard !proposal.steps.isEmpty else {
            throw TaskPlannerError.noSteps
        }

        guard proposal.steps.count <= maxPlanSteps else {
            throw TaskPlannerError.tooManySteps(
                proposal.steps.count
            )
        }

        let sorted = proposal.steps.sorted {
            $0.order < $1.order
        }

        let expectedOrders = Array(1...sorted.count)

        guard sorted.map(\.order) == expectedOrders else {
            throw TaskPlannerError.invalidStructuredResponse
        }

        // Generate trusted internal UUIDs ourselves.
        // Never trust UUIDs proposed by the LLM.

        var idsByOrder: [Int: UUID] = [:]

        for step in sorted {
            idsByOrder[step.order] = UUID()
        }

        let steps: [PlanStep] = try sorted.map { proposalStep in

            // Validate dependencies before materializing the step.

            for dependency in proposalStep.dependsOn {

                guard
                    dependency > 0,
                    dependency < proposalStep.order,
                    idsByOrder[dependency] != nil
                else {
                    throw TaskPlannerError.invalidDependency(
                        step: proposalStep.order,
                        dependency: dependency
                    )
                }
            }

            // Every executable step must define at least one
            // observable success criterion.

            guard !proposalStep.successCriteria.isEmpty else {
                throw TaskPlannerError.invalidStructuredResponse
            }

            guard let stepID = idsByOrder[proposalStep.order] else {
                throw TaskPlannerError.invalidStructuredResponse
            }

            return PlanStep(
                id: stepID,
                order: proposalStep.order,
                title: proposalStep.title,
                instructions: proposalStep.instructions,
                status: .pending,
                capabilityId: proposalStep.capabilityId,
                dependencyStepIds:
                    proposalStep.dependsOn.compactMap {
                        idsByOrder[$0]
                    },
                successCriteria: proposalStep.successCriteria,
                riskLevel:
                    PlanStepRiskLevel(
                        rawValue: proposalStep.risk.rawValue
                    ) ?? .low,
                requiresApproval: proposalStep.requiresApproval,
                canRunInBackground: proposalStep.canRunInBackground,
                estimatedEffort:
                    PlanStepEffort(
                        rawValue: proposalStep.estimatedEffort.rawValue
                    ) ?? .short,
                maxAttempts: 3
            )
        }

        return TaskPlan(
            summary: proposal.summary,
            steps: steps
        )
    }
}

// MARK: - Planner Response DTOs

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

// MARK: - Planner Types

private enum PlannerRisk: String, Codable {
    case low
    case medium
    case high
    case critical
}

private enum PlannerEffort: String, Codable {
    case short
    case medium
    case long
}

// MARK: - JSON Cleanup

private extension String {

    func removingMarkdownJSONFence() -> String {

        var value = trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if value.hasPrefix("```json") {

            value.removeFirst("```json".count)

        } else if value.hasPrefix("```") {

            value.removeFirst(3)
        }

        value = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if value.hasSuffix("```") {

            value.removeLast(3)
        }

        return value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}
