import Foundation

@MainActor
final class LocalTextFileReadCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_text_file_read"
    let name = "Local Text File Read"
    let capabilityDescription = "Reads a scoped UTF-8 text file locally and exposes the exact text as structured output for later workflow steps."
    let keywords = ["read text file", "διάβασε αρχείο κειμένου", "διάβασε το αρχείο"]
    private(set) var status: AgentCapabilityStatus = .idle

    private let locations: FileLocationService

    init(locations: FileLocationService? = nil) {
        self.locations = locations ?? FileLocationService.shared
    }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .files,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: ["file_save"],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_text_file_read capability απαιτεί structured path για να μην μαντεύει ποιο αρχείο πρέπει να διαβάσει.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard invocation.capabilityId == id,
              invocation.operation == "read",
              let path = invocation.arguments["path"],
              let resolved = locations.resolveExistingPath(path) else {
            return .reply("Το text file path δεν είναι διαθέσιμο μέσα στο εγκεκριμένο security scope.")
        }
        defer { resolved.stopAccessing() }

        let url = resolved.url
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return .reply("Το αρχείο δεν είναι υποστηριζόμενο plain-text format.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000 else { return .reply("Το αρχείο υπερβαίνει το local chaining limit του 1 MB.") }
        guard let text = String(data: data, encoding: .utf8) else { return .reply("Το αρχείο δεν είναι έγκυρο UTF-8 text.") }

        let human = "LOCAL TEXT FILE READ\n\nfile: \(url.lastPathComponent)\ncharacters: \(text.count)\nbytes: \(data.count)\n\nPREVIEW\n\(String(text.prefix(12_000)))"
        return .reply(StructuredStepOutputCodec.append(values: ["text": text, "path": url.path], to: human))
    }

    func resolve(_ action: ProposedAction) { }

    private static let allowedExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "yaml", "yml", "xml", "swift"]
}
