import Foundation

@MainActor
final class LocalDocumentCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_documents"
    let name = "Local Documents"
    let capabilityDescription = "Deterministic local text-document inspection, search and safe transforms inside the approved filesystem scope."
    let keywords = ["document", "text file", "find in file", "word count", "γραμμές", "αρχείο κειμένου", "βρες στο αρχείο"]
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
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        return .reply("Το local_documents capability εκτελείται μέσω structured invocation ώστε paths και transforms να μην μαντεύονται από φυσική γλώσσα.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong capability invocation.") }
        guard let path = invocation.arguments["path"], let resolved = locations.resolveExistingPath(path) else {
            return .reply("Το document path δεν υπάρχει μέσα στο εγκεκριμένο security scope.")
        }
        defer { resolved.stopAccessing() }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        let url = resolved.url
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return .reply("Υποστηρίζονται μόνο local plain-text formats: txt, md, csv, json, log, yaml/yml, xml, swift.")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.utf8.count <= 10_000_000 else { return .reply("Το αρχείο υπερβαίνει το local safety limit των 10 MB.") }

        switch invocation.operation {
        case "stats":
            let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return .reply("DOCUMENT STATS\n\nfile: \(url.lastPathComponent)\ncharacters: \(text.count)\nwords: \(words)\nlines: \(lines)\nbytes: \(text.utf8.count)")

        case "find":
            guard let query = invocation.arguments["query"], !query.isEmpty else { return .reply("Missing query.") }
            let matches = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line -> String? in
                line.localizedCaseInsensitiveContains(query) ? "\(index + 1): \(String(line.prefix(500)))" : nil
            }
            return .reply(matches.isEmpty ? "Δεν βρέθηκαν matches." : "MATCHES (\(matches.count))\n\n" + matches.prefix(200).joined(separator: "\n"))

        case "head":
            let count = min(max(Int(invocation.arguments["lines"] ?? "40") ?? 40, 1), 500)
            return .reply(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(count).joined(separator: "\n"))

        case "normalize_whitespace":
            let normalized = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            return .reply(String(normalized.prefix(20_000)))

        default:
            return .reply("Unsupported local document operation: \(invocation.operation)")
        }
    }

    private static let allowedExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "yaml", "yml", "xml", "swift"]
}
