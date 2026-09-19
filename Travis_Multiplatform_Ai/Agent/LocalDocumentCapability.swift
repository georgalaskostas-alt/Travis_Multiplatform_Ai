import Foundation

@MainActor
final class LocalDocumentCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_documents"
    let name = "Local Documents"
    let capabilityDescription = "Deterministic local text-document inspection, search and safe transforms inside the approved filesystem scope."
    let keywords = ["document", "text file", "find in file", "word count", "γραμμές", "αρχείο κειμένου", "βρες στο αρχείο"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

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
                declaredEffects: [.readOnly, .localMutation],
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

        let url = resolved.url
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return .reply("Υποστηρίζονται μόνο local plain-text formats: txt, md, csv, json, log, yaml/yml, xml, swift.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000 else { return .reply("Το αρχείο υπερβαίνει το local safety limit των 10 MB.") }
        guard let text = String(data: data, encoding: .utf8) else { return .reply("Το αρχείο δεν είναι έγκυρο UTF-8 text.") }

        switch invocation.operation {
        case "stats":
            let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return .reply("DOCUMENT STATS\n\nfile: \(url.lastPathComponent)\ncharacters: \(text.count)\nwords: \(words)\nlines: \(lines)\nbytes: \(data.count)")

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
            return .reply(String(normalizeWhitespace(text).prefix(20_000)))

        case "replace_preview":
            guard let find = invocation.arguments["find"], !find.isEmpty,
                  let replacement = invocation.arguments["replace"] else { return .reply("Missing find/replace arguments.") }
            let count = text.components(separatedBy: find).count - 1
            let transformed = text.replacingOccurrences(of: find, with: replacement)
            return .reply("REPLACE PREVIEW\n\noccurrences: \(count)\nchanged: \(transformed != text)\n\n" + String(transformed.prefix(20_000)))

        case "write_normalized":
            return try proposal(sourceURL: url, original: text, transformed: normalizeWhitespace(text), operation: "normalize whitespace", outputPath: invocation.arguments["output_path"])

        case "write_replace":
            guard let find = invocation.arguments["find"], !find.isEmpty,
                  let replacement = invocation.arguments["replace"] else { return .reply("Missing find/replace arguments.") }
            return try proposal(sourceURL: url, original: text, transformed: text.replacingOccurrences(of: find, with: replacement), operation: "replace '\(find)'", outputPath: invocation.arguments["output_path"])

        case "write_sort_lines":
            let transformed = sortedLines(text, descending: Self.bool(invocation.arguments["descending"]))
            return try proposal(sourceURL: url, original: text, transformed: transformed, operation: "sort lines", outputPath: invocation.arguments["output_path"])

        case "write_unique_lines":
            let transformed = uniqueLines(text, caseInsensitive: Self.bool(invocation.arguments["case_insensitive"], default: true))
            return try proposal(sourceURL: url, original: text, transformed: transformed, operation: "remove duplicate lines", outputPath: invocation.arguments["output_path"])

        case "write_pretty_json":
            guard url.pathExtension.lowercased() == "json" else { return .reply("Pretty JSON εφαρμόζεται μόνο σε .json αρχεία.") }
            let transformed = try prettyJSON(data)
            return try proposal(sourceURL: url, original: text, transformed: transformed, operation: "pretty-print JSON", outputPath: invocation.arguments["output_path"])

        default:
            return .reply("Unsupported local document operation: \(invocation.operation)")
        }
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payload = action.payload,
              let data = payload.data(using: .utf8),
              let mutation = try? JSONDecoder().decode(DocumentMutation.self, from: data),
              let source = locations.resolveExistingPath(mutation.sourcePath) else { return }
        defer { source.stopAccessing() }

        do {
            let current = try Data(contentsOf: source.url)
            guard current == Data(base64Encoded: mutation.originalBase64) else {
                onExecutionUpdate?("❌ Document transform cancelled: source changed after approval preview.")
                return
            }
            guard let outputDirectory = locations.resolveSaveDirectory(for: (mutation.outputPath as NSString).deletingLastPathComponent) else {
                onExecutionUpdate?("❌ Document transform cancelled: output folder is outside approved scope.")
                return
            }
            defer { outputDirectory.stopAccessing() }
            let target = outputDirectory.url.appendingPathComponent((mutation.outputPath as NSString).lastPathComponent)
            let transformed = Data(base64Encoded: mutation.transformedBase64) ?? Data()
            try transformed.write(to: target, options: .atomic)
            onExecutionUpdate?("✅ Local document transform saved: \(target.path)")
        } catch {
            onExecutionUpdate?("❌ Document transform failed: \(error.localizedDescription)")
        }
    }

    private struct DocumentMutation: Codable {
        let sourcePath: String
        let outputPath: String
        let originalBase64: String
        let transformedBase64: String
    }

    private enum DocumentTransformError: LocalizedError {
        case invalidJSON
        var errorDescription: String? { "Το JSON δεν είναι έγκυρο και δεν έγινε καμία αλλαγή." }
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private func sortedLines(_ text: String, descending: Bool) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sorted = lines.sorted { lhs, rhs in
            let order = lhs.localizedStandardCompare(rhs)
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return sorted.joined(separator: "\n")
    }

    private func uniqueLines(_ text: String, caseInsensitive: Bool) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let key = caseInsensitive ? line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) : line
            if seen.insert(key).inserted { result.append(line) }
        }
        return result.joined(separator: "\n")
    }

    private func prettyJSON(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { throw DocumentTransformError.invalidJSON }
        return text + "\n"
    }

    private func proposal(sourceURL: URL, original: String, transformed: String, operation: String, outputPath: String?) throws -> CapabilityOutcome {
        guard transformed != original else { return .reply("Δεν υπάρχει αλλαγή προς αποθήκευση.") }
        let destination = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPath: String
        if let destination, !destination.isEmpty {
            finalPath = destination
        } else {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            finalPath = sourceURL.deletingLastPathComponent().appendingPathComponent("\(stem)-travis.\(ext)").path
        }
        let payload = DocumentMutation(
            sourcePath: sourceURL.path,
            outputPath: finalPath,
            originalBase64: Data(original.utf8).base64EncodedString(),
            transformedBase64: Data(transformed.utf8).base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else { return .reply("Failed to encode document mutation.") }
        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Local document transform: \(operation)",
            reasoning: "Το transformed content υπολογίστηκε τοπικά. Η εγγραφή απαιτεί approval και το source ξαναελέγχεται πριν το write.",
            expectedImpact: "Θα γραφτεί νέο/επιλεγμένο output file: \(finalPath). Το source δεν τροποποιείται in-place από default.",
            riskLevel: .medium,
            payload: payloadText,
            filename: (finalPath as NSString).lastPathComponent,
            location: (finalPath as NSString).deletingLastPathComponent
        ))
    }

    private static func bool(_ value: String?, default fallback: Bool = false) -> Bool {
        guard let value else { return fallback }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static let allowedExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "yaml", "yml", "xml", "swift"]
}
