import Foundation
import CryptoKit

@MainActor
final class LocalDirectoryAnalysisCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_directory_analysis"
    let name = "Local Directory Analysis"
    let capabilityDescription = "Zero-token folder inventory, extension summaries, largest-file reports and duplicate-file detection inside approved scope."
    let keywords = ["folder inventory", "largest files", "duplicate files", "ανάλυση φακέλου", "διπλότυπα αρχεία", "μεγαλύτερα αρχεία"]
    private(set) var status: AgentCapabilityStatus = .idle

    private let locations: FileLocationService
    private let maxEnumeratedItems = 50_000
    private let maxHashBytes = 500_000_000
    private let maxSingleHashBytes = 100_000_000

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
                timeoutSeconds: 90,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_directory_analysis capability χρησιμοποιεί structured arguments ώστε να αναλύει συγκεκριμένο φάκελο χωρίς AI tokens.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id,
              let rawPath = invocation.arguments["path"],
              let scoped = locations.resolveExistingPath(rawPath) else {
            return .reply("Ο φάκελος δεν είναι διαθέσιμος μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { scoped.stopAccessing() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scoped.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .reply("Το path δεν είναι φάκελος.")
        }

        let recursive = Self.bool(invocation.arguments["recursive"], fallback: true)
        let entries = try collectFiles(root: scoped.url, recursive: recursive)
        let output: String

        switch invocation.operation {
        case "inventory":
            output = inventory(entries: entries, root: scoped.url)
        case "extension_summary":
            output = extensionSummary(entries: entries, root: scoped.url)
        case "largest_files":
            let limit = min(max(Int(invocation.arguments["limit"] ?? "25") ?? 25, 1), 200)
            output = largestFiles(entries: entries, root: scoped.url, limit: limit)
        case "duplicates":
            output = try duplicateFiles(entries: entries, root: scoped.url)
        default:
            return .reply("Unsupported directory analysis operation: \(invocation.operation)")
        }

        return .reply(StructuredStepOutputCodec.append(values: ["text": output], to: output))
    }

    func resolve(_ action: ProposedAction) { }

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date?
    }

    private func collectFiles(root: URL, recursive: Bool) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []
        if recursive {
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    urls.append(url)
                    if urls.count >= maxEnumeratedItems { break }
                }
            }
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return Entry(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
    }

    private func inventory(entries: [Entry], root: URL) -> String {
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        let newest = entries.compactMap(\.modified).max().map { Self.iso8601.string(from: $0) } ?? "unknown"
        return """
        LOCAL DIRECTORY INVENTORY

        root: \(root.path)
        files: \(entries.count)
        total_bytes: \(total)
        newest_modified: \(newest)
        """
    }

    private func extensionSummary(entries: [Entry], root: URL) -> String {
        var groups: [String: (count: Int, bytes: Int64)] = [:]
        for entry in entries {
            let ext = entry.url.pathExtension.lowercased().isEmpty ? "(no extension)" : entry.url.pathExtension.lowercased()
            let current = groups[ext] ?? (0, 0)
            groups[ext] = (current.count + 1, current.bytes + entry.size)
        }
        let rows = groups.sorted { lhs, rhs in
            lhs.value.bytes != rhs.value.bytes ? lhs.value.bytes > rhs.value.bytes : lhs.key < rhs.key
        }.map { "\($0.key) | files=\($0.value.count) | bytes=\($0.value.bytes)" }.joined(separator: "\n")
        return "LOCAL DIRECTORY EXTENSION SUMMARY\n\nroot: \(root.path)\n\n\(rows.isEmpty ? "(empty)" : rows)"
    }

    private func largestFiles(entries: [Entry], root: URL, limit: Int) -> String {
        let rows = entries.sorted { $0.size > $1.size }.prefix(limit).map { entry in
            let relative = relativePath(entry.url, root: root)
            return "\(entry.size) B | \(relative)"
        }.joined(separator: "\n")
        return "LOCAL DIRECTORY LARGEST FILES\n\nroot: \(root.path)\ncount: \(min(entries.count, limit))\n\n\(rows.isEmpty ? "(empty)" : rows)"
    }

    private func duplicateFiles(entries: [Entry], root: URL) throws -> String {
        let sizeGroups = Dictionary(grouping: entries.filter { $0.size > 0 && $0.size <= Int64(maxSingleHashBytes) }, by: \.size)
            .filter { $0.value.count > 1 }

        var hashedBytes = 0
        var hashGroups: [String: [Entry]] = [:]
        for (_, group) in sizeGroups {
            for entry in group {
                hashedBytes += Int(entry.size)
                guard hashedBytes <= maxHashBytes else {
                    return "LOCAL DIRECTORY DUPLICATES\n\nroot: \(root.path)\n\nHash safety budget reached after \(hashedBytes) bytes. Narrow the folder or use a smaller scope."
                }
                let data = try Data(contentsOf: entry.url, options: [.mappedIfSafe])
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                hashGroups[digest, default: []].append(entry)
            }
        }

        let duplicates = hashGroups.values.filter { $0.count > 1 }
        guard !duplicates.isEmpty else { return "LOCAL DIRECTORY DUPLICATES\n\nroot: \(root.path)\n\nNo duplicate files found." }
        let sections = duplicates.enumerated().map { index, group in
            let size = group.first?.size ?? 0
            let paths = group.map { relativePath($0.url, root: root) }.joined(separator: "\n")
            return "GROUP \(index + 1) | size=\(size) B | copies=\(group.count)\n\(paths)"
        }.joined(separator: "\n\n")
        return "LOCAL DIRECTORY DUPLICATES\n\nroot: \(root.path)\ngroups: \(duplicates.count)\n\n\(sections)"
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    private static func bool(_ value: String?, fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static let iso8601 = ISO8601DateFormatter()
}
