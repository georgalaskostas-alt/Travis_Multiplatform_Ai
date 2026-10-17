import Foundation

@MainActor
final class LocalTextTransformCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_text_transform"
    let name = "Local Text Transform"
    let capabilityDescription = "Zero-token deterministic text transforms that can consume verified output from earlier workflow steps."
    let keywords = ["sort lines", "unique lines", "trim text", "uppercase", "lowercase", "ταξινόμησε γραμμές", "μοναδικές γραμμές"]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .productivity,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: [],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_text_transform capability χρησιμοποιεί structured input ώστε να μη μαντεύει ποιο κείμενο πρέπει να αλλάξει.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard invocation.capabilityId == id else { return .reply("Wrong capability invocation.") }
        guard let text = invocation.arguments["text"] else { return .reply("Λείπει το κείμενο εισόδου.") }
        guard text.utf8.count <= 1_000_000 else { return .reply("Το κείμενο υπερβαίνει το local safety limit του 1 MB.") }

        let transformed: String
        switch invocation.operation {
        case "trim":
            transformed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "uppercase":
            transformed = text.uppercased()
        case "lowercase":
            transformed = text.lowercased()
        case "sort_lines":
            transformed = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case "unique_lines":
            var seen = Set<String>()
            transformed = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { seen.insert($0).inserted }
                .joined(separator: "\n")
        case "sort_unique_lines":
            transformed = Array(Set(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case "replace":
            guard let find = invocation.arguments["find"], !find.isEmpty,
                  let replacement = invocation.arguments["replace"] else { return .reply("Λείπουν τα find/replace arguments.") }
            transformed = text.replacingOccurrences(of: find, with: replacement)
        default:
            return .reply("Μη υποστηριζόμενη local text operation: \(invocation.operation)")
        }

        let human = "LOCAL TEXT TRANSFORM\n\noperation: \(invocation.operation)\ninput characters: \(text.count)\noutput characters: \(transformed.count)\n\nPREVIEW\n\(String(transformed.prefix(12_000)))"
        return .reply(StructuredStepOutputCodec.append(values: ["text": transformed], to: human))
    }

    func resolve(_ action: ProposedAction) { }
}
