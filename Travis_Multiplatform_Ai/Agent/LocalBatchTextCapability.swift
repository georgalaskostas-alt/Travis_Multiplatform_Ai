import Foundation
import CryptoKit

@MainActor
final class LocalBatchTextCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_batch_text"
    let name = "Local Batch Text"
    let capabilityDescription = "Zero-token batch transforms for many local text/JSON files with exact-file previews, source fingerprints and approval-gated writes."
    let keywords = ["batch text", "all text files", "όλα τα αρχεία", "μαζική επεξεργασία", "batch json"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let locations: FileLocationService
    private let maxFiles = 1_000
    private let maxBytesPerFile = 10_000_000
    private let maxTotalBytes = 100_000_000

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
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 120,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_batch_text capability χρησιμοποιεί structured arguments ώστε να μην επιλέγει αυθαίρετα αρχεία ή transforms.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong capability invocation.") }
        #if !os(macOS)
        return .reply("Η μαζική τοπική επεξεργασία αρχείων είναι διαθέσιμη προς το παρόν στο macOS build.")
        #else
        guard invocation.operation == "transform_files" else {
            return .reply("Unsupported local batch operation: \(invocation.operation)")
        }
        guard let sourcePath = invocation.arguments["sourcePath"],
              let source = locations.resolveExistingPath(sourcePath) else {
            return .reply("Ο source folder δεν είναι μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { source.stopAccessing() }

        let names = splitNames(invocation.arguments["names"])
        guard !names.isEmpty else { return .reply("Δεν υπάρχουν συγκεκριμένα filenames προς επεξεργασία.") }
        guard names.count <= maxFiles else { return .reply("Το batch υπερβαίνει το safety limit των \(maxFiles) αρχείων.") }

        let transform = invocation.arguments["transform"] ?? ""
        guard Self.allowedTransforms.contains(transform) else { return .reply("Μη υποστηριζόμενο batch transform: \(transform)") }

        let destinationPath = invocation.arguments["destinationPath"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputDirectory: FileLocationService.ScopedURL?
        if let destinationPath, !destinationPath.isEmpty {
            outputDirectory = locations.resolveExistingPath(destinationPath)
            guard outputDirectory != nil else { return .reply("Ο destination folder δεν είναι μέσα στο εγκεκριμένο filesystem scope.") }
        } else {
            outputDirectory = nil
        }
        defer { outputDirectory?.stopAccessing() }

        var snapshots: [FileSnapshot] = []
        var totalBytes = 0
        var preview: [String] = []
        for name in names {
            guard isSafeSimpleName(name) else { return .reply("Μη ασφαλές filename: \(name)") }
            let sourceURL = source.url.appendingPathComponent(name)
            let data = try Data(contentsOf: sourceURL)
            guard data.count <= maxBytesPerFile else { return .reply("Το \(name) υπερβαίνει το όριο των 10 MB.") }
            totalBytes += data.count
            guard totalBytes <= maxTotalBytes else { return .reply("Το batch υπερβαίνει το συνολικό safety limit των 100 MB.") }
            guard let text = String(data: data, encoding: .utf8) else { return .reply("Το \(name) δεν είναι UTF-8 text.") }
            _ = try transformText(text, operation: transform, find: invocation.arguments["find"], replace: invocation.arguments["replace"])

            let targetURL: URL
            if let outputDirectory {
                targetURL = outputDirectory.url.appendingPathComponent(name)
            } else {
                targetURL = siblingOutputURL(for: sourceURL)
            }
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                return .reply("Υπάρχει ήδη output file: \(targetURL.path). Δεν θα γίνει overwrite.")
            }
            snapshots.append(FileSnapshot(name: name, sha256: sha256(data), targetPath: targetURL.path))
            preview.append("\(name) → \(targetURL.lastPathComponent)")
        }

        let payload = MutationPayload(
            sourcePath: source.url.path,
            transform: transform,
            find: invocation.arguments["find"],
            replace: invocation.arguments["replace"],
            files: snapshots
        )
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else { return .reply("Απέτυχε η προετοιμασία batch proposal.") }

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Batch transform \(snapshots.count) files — \(transform)",
            reasoning: "Ο TRAVIS επέλεξε συγκεκριμένα verified filenames, υπολόγισε fingerprint για κάθε source και δεν θα κάνει overwrite υπάρχον output.",
            expectedImpact: preview.prefix(30).joined(separator: "\n") + (preview.count > 30 ? "\n… +\(preview.count - 30) more" : ""),
            riskLevel: .medium,
            payload: payloadText,
            filename: nil,
            location: source.url.path
        ))
        #endif
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MutationPayload.self, from: data) else { return }
        #if os(macOS)
        guard let source = locations.resolveExistingPath(payload.sourcePath) else {
            onExecutionUpdate?("❌ Batch transform cancelled: source folder is outside approved scope.")
            return
        }
        defer { source.stopAccessing() }

        do {
            // All preflight checks happen before the first write so a changed
            // source or output collision stops the whole batch atomically enough
            // for user-facing semantics.
            var prepared: [(URL, URL, Data)] = []
            for snapshot in payload.files {
                guard isSafeSimpleName(snapshot.name) else { throw BatchError.unsafeName(snapshot.name) }
                let sourceURL = source.url.appendingPathComponent(snapshot.name)
                let sourceData = try Data(contentsOf: sourceURL)
                guard sha256(sourceData) == snapshot.sha256 else { throw BatchError.sourceChanged(snapshot.name) }
                guard let text = String(data: sourceData, encoding: .utf8) else { throw BatchError.invalidUTF8(snapshot.name) }
                let transformed = try transformText(text, operation: payload.transform, find: payload.find, replace: payload.replace)
                let targetURL = URL(fileURLWithPath: snapshot.targetPath)
                guard !FileManager.default.fileExists(atPath: targetURL.path) else { throw BatchError.collision(targetURL.path) }
                guard let targetDirectory = locations.resolveSaveDirectory(for: targetURL.deletingLastPathComponent().path) else {
                    throw BatchError.invalidDestination(targetURL.deletingLastPathComponent().path)
                }
                targetDirectory.stopAccessing()
                prepared.append((sourceURL, targetURL, Data(transformed.utf8)))
            }

            var written: [URL] = []
            do {
                for (_, target, transformed) in prepared {
                    try transformed.write(to: target, options: .atomic)
                    written.append(target)
                }
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            onExecutionUpdate?("✅ Batch transform completed: \(written.count) files created.")
        } catch {
            onExecutionUpdate?("❌ Batch transform stopped safely: \(error.localizedDescription)")
        }
        #endif
    }

    private struct FileSnapshot: Codable {
        let name: String
        let sha256: String
        let targetPath: String
    }

    private struct MutationPayload: Codable {
        let sourcePath: String
        let transform: String
        let find: String?
        let replace: String?
        let files: [FileSnapshot]
    }

    private enum BatchError: LocalizedError {
        case sourceChanged(String), unsafeName(String), invalidUTF8(String), collision(String), invalidDestination(String), invalidJSON
        var errorDescription: String? {
            switch self {
            case .sourceChanged(let name): return "Το source \(name) άλλαξε μετά το preview."
            case .unsafeName(let name): return "Μη ασφαλές filename: \(name)"
            case .invalidUTF8(let name): return "Το \(name) δεν είναι UTF-8 text."
            case .collision(let path): return "Υπάρχει ήδη output file: \(path)"
            case .invalidDestination(let path): return "Ο destination folder δεν είναι εγκεκριμένος: \(path)"
            case .invalidJSON: return "Μη έγκυρο JSON."
            }
        }
    }

    private func transformText(_ text: String, operation: String, find: String?, replace: String?) throws -> String {
        switch operation {
        case "unique_lines":
            var seen = Set<String>()
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case "sort_lines":
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: "\n")
        case "normalize_whitespace":
            return text.split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\n")
        case "pretty_json":
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                  let output = String(data: pretty, encoding: .utf8) else { throw BatchError.invalidJSON }
            return output
        case "replace":
            guard let find, !find.isEmpty, let replace else { return text }
            return text.replacingOccurrences(of: find, with: replace)
        default:
            return text
        }
    }

    private func siblingOutputURL(for sourceURL: URL) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let name = ext.isEmpty ? "\(stem)-travis" : "\(stem)-travis.\(ext)"
        return sourceURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func splitNames(_ value: String?) -> [String] {
        value?.split(separator: "|").map(String.init).filter { !$0.isEmpty } ?? []
    }

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("|")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let allowedTransforms: Set<String> = ["unique_lines", "sort_lines", "normalize_whitespace", "pretty_json", "replace"]
}
