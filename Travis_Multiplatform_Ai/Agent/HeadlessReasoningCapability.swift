import Foundation

/// Read-only reasoning/synthesis capability. It can think, summarize, compare and
/// produce recommendations but cannot mutate files, execute shell commands, place
/// orders or apply its own code. That separation makes the same logical operation
/// safe to hand to the Always-On worker as `ai.reason`.
@MainActor
final class HeadlessReasoningCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "headless_reasoning"
    let name = "Headless AI Reasoning"
    let capabilityDescription = "Background-safe AI reasoning for analysis, synthesis, planning, comparison and report generation from provided context. Read-only: no file/code/exchange mutation."
    let keywords = [
        "reasoning mode", "deep analysis", "synthesize evidence", "reason from evidence",
        "λειτουργια συλλογισμου", "λειτουργία συλλογισμού", "συνθεση ευρηματων", "σύνθεση ευρημάτων"
    ]
    private(set) var status: AgentCapabilityStatus = .idle
    private let aiService: AIService

    init(aiService: AIService = .shared) { self.aiService = aiService }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .research,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 180,
                maxAttempts: 3
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
    func resolve(_ action: ProposedAction) {}

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        let context = recentHistory.isEmpty ? "" : "\n\nRECENT VERIFIED CONTEXT:\n\(recentHistory.suffix(8).promptTranscript)"
        let guardrail = """
        You are TRAVIS in READ-ONLY reasoning mode.
        Perform the requested analysis, synthesis, comparison, prioritization or report using only supplied/verified context plus clearly-labelled general reasoning.
        Distinguish observations, inferences, uncertainty and recommendations.
        Never claim to have executed code, changed files/GUI, placed trades, changed permissions or mutated external state.
        For financial/market topics, treat signals as probabilistic and never promise profit.
        If evidence is insufficient, state exactly what is missing instead of inventing it.

        USER TASK:
        \(command)\(context)
        """
        return .reply(try await aiService.generateText(prompt: guardrail, maxTokens: 3200))
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        guard invocation.operation == "reason" || invocation.operation == "synthesize" else {
            return .reply("Unsupported reasoning operation: \(invocation.operation)")
        }
        guard let prompt = invocation.arguments["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return .reply("Reasoning operation requires a non-empty prompt.")
        }
        return try await handle(command: prompt, recentHistory: [])
    }
}
