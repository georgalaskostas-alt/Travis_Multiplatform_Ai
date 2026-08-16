import Foundation

/// Semantic fallback router over the real capability registry.
/// Exact/keyword routing remains deterministic and cheap; this service is used
/// only when no specialist keyword matched, preventing the catch-all text tool
/// from swallowing research/API/file requests expressed in natural language.
@MainActor
final class CapabilitySelectionService {
    private struct Decision: Decodable {
        let capabilityId: String?
        let confidence: Double?
    }

    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func select(
        message: String,
        capabilities: [AgentCapability],
        recentHistory: [ChatMessage]
    ) async -> AgentCapability? {
        let registry = CapabilityRegistry(capabilities: capabilities)
        let specialist = registry.descriptors.filter { $0.id != "text_task" }
        guard !specialist.isEmpty else { return nil }

        let catalog = specialist.map { descriptor in
            let effects = descriptor.policy.declaredEffects.map(\.rawValue).joined(separator: ",")
            return "\(descriptor.id) | domain=\(descriptor.domain.rawValue) | effects=\(effects) | \(descriptor.summary)"
        }.joined(separator: "\n")

        let prompt = """
        You route one user message to exactly one TRAVIS capability.
        Select a specialist capability ONLY if it clearly provides real tools/evidence needed for the request.
        If ordinary conversation/reasoning is enough, return null so text_task handles it.
        Never select repository_context for public web research.
        Never select web_research for local repository/source inspection.
        Select public_api only when the user actually supplied or clearly refers to an HTTP/API endpoint or API operation.
        Select managed_files only for files already managed/created by TRAVIS.
        Return JSON only: {"capabilityId":null,"confidence":0.0}

        CAPABILITIES
        \(catalog)

        RECENT CONTEXT
        \(recentHistory.suffix(5).promptTranscript)

        USER MESSAGE
        \(message)
        """

        guard let raw = try? await aiService.generateText(prompt: prompt, maxTokens: 300),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let decision = try? JSONDecoder().decode(Decision.self, from: data),
              let id = decision.capabilityId,
              (decision.confidence ?? 0) >= 0.62 else {
            return nil
        }

        return capabilities.first { $0.id == id && $0.id != "text_task" }
    }
}
