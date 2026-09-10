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
    let keywords = ["analyze","analyse","summarize","compare","reason","report","αναλυσε","ανάλυσε","συγκρινε","σύγκρινε","συνοψη","σύνοψη","αναφορα","αναφορά"]
    private(set) var status: AgentCapabilityStatus = .idle
    private let aiService: AIService

    init(aiService: AIService = .shared) { self.aiService = aiService }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id:id,
            displayName:name,
            summary:capabilityDescription,
            domain:.general,
            keywords:keywords,
            policy:CapabilityExecutionPolicy(declaredEffects:[.readOnly],supportsBackgroundExecution:true,supportsProjectContext:true,timeoutSeconds:180,maxAttempts:3)
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
    func resolve(_ action: ProposedAction) {}

    func handle(command:String,recentHistory:[ChatMessage]) async throws -> CapabilityOutcome {
        status = .running; defer { status = .idle }
        let context = recentHistory.isEmpty ? "" : "\n\nRECENT CONTEXT:\n\(recentHistory.promptTranscript)"
        let guardrail = """
        You are TRAVIS in READ-ONLY reasoning mode. Answer the user's analysis/synthesis task accurately.
        You may recommend actions but must not claim to have executed code, changed files, placed trades, changed GUI, or mutated external state.
        For market/trading topics, uncertainty and risk must be explicit; do not promise profit.
        USER TASK:\n\(command)\(context)
        """
        return .reply(try await aiService.generateText(prompt:guardrail,maxTokens:2400))
    }

    func handle(invocation:DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        guard invocation.operation == "reason" || invocation.operation == "synthesize" else { return .reply("Unsupported reasoning operation.") }
        guard let prompt = invocation.arguments["prompt"], !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return .reply("Reasoning operation requires prompt=...") }
        return try await handle(command:prompt,recentHistory:[])
    }
}
