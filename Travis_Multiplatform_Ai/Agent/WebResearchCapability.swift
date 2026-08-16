import Foundation

@MainActor
final class WebResearchCapability: AgentCapability {
    let id = "web_research"
    let name = "Web Research"
    let capabilityDescription = "Κάνει πραγματική τρέχουσα έρευνα στο δημόσιο web με πηγές μέσω OpenAI Responses web search."
    let keywords: [String] = [
        "ψάξε στο web", "ψαξε στο web", "ψάξε στο internet", "ψαξε στο internet",
        "αναζήτησε στο web", "αναζητησε στο web", "web research", "research online",
        "τελευταία νέα", "τελευταια νεα", "latest news", "βρες online"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .research,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: [],
                requiresExplicitApproval: false,
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 180,
                maxAttempts: 2
            ),
            version: 1
        )
    }

    private let service: OpenAIWebResearchService

    init(service: OpenAIWebResearchService = .shared) {
        self.service = service
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let context = recentHistory.isEmpty ? nil : recentHistory.suffix(6).promptTranscript
        let result = try await service.research(query: command, context: context)

        let sourceBlock: String
        if result.sources.isEmpty {
            sourceBlock = ""
        } else {
            sourceBlock = "\n\nSOURCES\n" + result.sources.prefix(12).enumerated().map {
                "\($0.offset + 1). \($0.element.title) — \($0.element.url)"
            }.joined(separator: "\n")
        }

        return .reply(result.text + sourceBlock)
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability: never creates or resolves mutations.
    }
}
