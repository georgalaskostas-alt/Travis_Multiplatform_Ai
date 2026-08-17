import Foundation

@MainActor
final class LocalFileSearchCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_file_search"
    let name = "Local File Search"
    let capabilityDescription = "Zero-token deterministic file search and filtering inside the approved security-scoped filesystem."
    let keywords = ["find files", "search files", "filter files", "βρες αρχεία", "αναζήτηση αρχείων", "αρχεία μεγαλύτερα"]
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
                timeoutSeconds: 45,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        return .reply("Το local_file_search capability χρησιμοποιεί structured arguments ώστε path και filters να είναι deterministic και να μη χρειάζονται AI tokens.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong capability invocation.") }
        guard let path = invocation.arguments["path"], let resolved = locations.resolveExistingPath(path) else {
            return .reply("Το search path δεν υπάρχει μέσα στο εγκεκριμένο security scope.")
        }
        defer { resolved.stopAccessing() }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        let recursive = Self.bool(invocation.arguments["recursive"], default: true)
        let includeDirectories = Self.bool(invocation.arguments["includeDirectories"], default: false)
        let nameContains = invocation.arguments["nameContains"]?.lowercased()
        let ext = invocation.arguments["extension"]?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let minBytes = invocation.arguments["minBytes"].flatMap(Int64.init)
        let maxBytes = invocation.arguments["maxBytes"].flatMap(Int64.init)
        let modifiedAfter = invocation.arguments["modifiedAfter"].flatMap(Self.iso8601.date)
        let modifiedBefore = invocation.arguments["modifiedBefore"].flatMap(Self.iso8601.date)
        let limit = min(max(Int(invocation.arguments["limit"] ?? "200") ?? 200, 1), 1000)

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []
        if recursive {
            if let enumerator = FileManager.default.enumerator(at: resolved.url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator { urls.append(url); if urls.count >= 50_000 { break } }
            }
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: resolved.url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        }

        var matches: [(URL, Int64, Date?, Bool)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            if isDir && !includeDirectories { continue }
            if let nameContains, !url.lastPathComponent.lowercased().contains(nameContains) { continue }
            if let ext, !ext.isEmpty, url.pathExtension.lowercased() != ext { continue }
            let size = Int64(values?.fileSize ?? 0)
            if let minBytes, size < minBytes { continue }
            if let maxBytes, size > maxBytes { continue }
            let modified = values?.contentModificationDate
            if let modifiedAfter, let modified, modified < modifiedAfter { continue }
            if let modifiedBefore, let modified, modified > modifiedBefore { continue }
            matches.append((url, size, modified, isDir))
            if matches.count >= limit { break }
        }

        guard !matches.isEmpty else { return .reply("Δεν βρέθηκαν αρχεία που να ταιριάζουν στα filters.") }
        let root = resolved.url.standardizedFileURL.path
        let rows = matches.map { item -> String in
            let relative = item.0.standardizedFileURL.path.replacingOccurrences(of: root + "/", with: "")
            let kind = item.3 ? "DIR" : "FILE"
            let modified = item.2.map { Self.iso8601.string(from: $0) } ?? "unknown"
            return "\(kind) | \(item.1) B | \(modified) | \(relative)"
        }.joined(separator: "\n")
        return .reply("LOCAL FILE SEARCH\n\nroot: \(root)\nmatches: \(matches.count)\n\n\(rows)")
    }

    private static func bool(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static let iso8601 = ISO8601DateFormatter()
}
