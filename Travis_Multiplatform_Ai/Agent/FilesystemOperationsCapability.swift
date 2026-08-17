import Foundation

@MainActor
final class FilesystemOperationsCapability: AgentCapability {
    let id = "filesystem_operations"
    let name = "Filesystem Operations"
    let capabilityDescription = "Scoped filesystem operations inside a user-authorized folder, with deterministic preview/collision checks and approval before mutations."
    let keywords: [String] = [
        "rename files", "batch rename", "αρχεια φακελου", "αρχεία φακέλου", "μετονομασε αρχεια", "μετονόμασε αρχεία",
        "αφαιρεσε απο τα filenames", "αφαίρεσε από τα filenames", "folder files", "filesystem"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

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
                timeoutSeconds: 90,
                maxAttempts: 2
            )
        )
    }

    var onExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let locations: FileLocationService

    init(aiService: AIService = .shared, locations: FileLocationService? = nil) {
        self.aiService = aiService
        self.locations = locations ?? FileLocationService.shared
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        #if !os(macOS)
        return .reply("Το scoped filesystem operations capability είναι διαθέσιμο προς το παρόν στο macOS build του TRAVIS.")
        #else
        let intent = try await classify(command, recentHistory: recentHistory)
        guard intent.operation != "none" else {
            return .reply("Δεν εντόπισα συγκεκριμένη filesystem εργασία. Μπορώ να κάνω ασφαλές folder listing ή batch rename μέσα σε εγκεκριμένο φάκελο.")
        }

        guard let path = intent.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return .reply("Χρειάζομαι συγκεκριμένο folder path για deterministic filesystem operation.")
        }

        if !locations.hasHomeDirectoryAccess {
            let granted = locations.requestHomeDirectoryAccess()
            guard granted else {
                return .reply("Δεν δόθηκε security-scoped folder access, επομένως δεν εκτελέστηκε filesystem operation.")
            }
        }

        guard let resolved = locations.resolveExistingPath(path) else {
            return .reply("Δεν μπόρεσα να επιβεβαιώσω ότι ο φάκελος υπάρχει μέσα στο εγκεκριμένο security scope: \(path)")
        }
        defer { resolved.stopAccessing() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .reply("Το path δεν είναι υπαρκτός φάκελος: \(resolved.url.path)")
        }

        switch intent.operation {
        case "list":
            return .reply(try renderListing(folder: resolved.url))
        case "rename":
            guard let find = intent.find, !find.isEmpty, let replace = intent.replace else {
                return .reply("Για batch rename χρειάζομαι το ακριβές filename text που θα αφαιρεθεί/αντικατασταθεί.")
            }
            return try buildRenameProposal(folder: resolved.url, find: find, replace: replace)
        default:
            return .reply("Η συγκεκριμένη filesystem operation δεν υποστηρίζεται ακόμη από το ασφαλές batch layer.")
        }
        #endif
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payload = action.payload,
              let data = payload.data(using: .utf8),
              let mutation = try? JSONDecoder().decode(BatchRenamePayload.self, from: data) else { return }

        #if os(macOS)
        guard let resolved = locations.resolveExistingPath(mutation.folderPath) else {
            onExecutionUpdate?("❌ Το approved filesystem batch δεν εκτελέστηκε: το folder scope δεν είναι πλέον διαθέσιμο.")
            return
        }
        defer { resolved.stopAccessing() }

        do {
            let result = try executeRenameBatch(mutation, folder: resolved.url)
            onExecutionUpdate?("✅ Batch rename: \(result.renamed) renamed, \(result.skipped) skipped — \(mutation.folderPath)")
        } catch {
            onExecutionUpdate?("❌ Batch rename σταμάτησε με ασφάλεια: \(error.localizedDescription)")
        }
        #endif
    }

    private struct IntentDecision: Decodable {
        let operation: String
        let path: String?
        let find: String?
        let replace: String?
    }

    private struct RenameEntry: Codable, Hashable {
        let from: String
        let to: String
    }

    private struct BatchRenamePayload: Codable {
        let folderPath: String
        let entries: [RenameEntry]
    }

    private enum FilesystemError: LocalizedError {
        case collision(String)
        case sourceChanged(String)

        var errorDescription: String? {
            switch self {
            case .collision(let name): return "Υπάρχει filename collision για \(name)."
            case .sourceChanged(let name): return "Το source file άλλαξε ή λείπει πριν την εκτέλεση: \(name)."
            }
        }
    }

    private func classify(_ command: String, recentHistory: [ChatMessage]) async throws -> IntentDecision {
        let prompt = """
        Parse a filesystem request for TRAVIS.
        Allowed operations: none, list, rename.
        path: exact user-supplied folder path; never invent one.
        For rename, find is the exact substring in each filename to remove/replace and replace is the replacement (empty string is allowed).
        Examples:
        "remove _portrait from filenames in /Users/me/Desktop/Photos" => {"operation":"rename","path":"/Users/me/Desktop/Photos","find":"_portrait","replace":""}
        Return JSON only.

        RECENT CONTEXT
        \(recentHistory.suffix(4).promptTranscript)

        USER REQUEST
        \(command)
        """
        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 450)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(IntentDecision.self, from: data) else {
            return IntentDecision(operation: "none", path: nil, find: nil, replace: nil)
        }
        return decoded
    }

    private func renderListing(folder: URL) throws -> String {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let rows = urls.prefix(200).map { $0.lastPathComponent }.joined(separator: "\n")
        let suffix = urls.count > 200 ? "\n… +\(urls.count - 200) more" : ""
        return "FOLDER LISTING\n\nPATH\n\(folder.path)\n\nITEMS\n\(urls.count)\n\n\(rows)\(suffix)"
    }

    private func buildRenameProposal(folder: URL, find: String, replace: String) throws -> CapabilityOutcome {
        let manager = FileManager.default
        let urls = try manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [RenameEntry] = []
        var targets = Set<String>()
        let existingNames = Set(urls.map(\.lastPathComponent))

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            let oldName = url.lastPathComponent
            guard oldName.contains(find) else { continue }
            let newName = oldName.replacingOccurrences(of: find, with: replace)
            guard newName != oldName, !newName.isEmpty else { continue }

            if targets.contains(newName) { throw FilesystemError.collision(newName) }
            if existingNames.contains(newName) && !entries.contains(where: { $0.from == newName }) {
                throw FilesystemError.collision(newName)
            }
            targets.insert(newName)
            entries.append(RenameEntry(from: oldName, to: newName))
        }

        guard !entries.isEmpty else {
            return .reply("Δεν βρέθηκαν αρχεία στον φάκελο που να περιέχουν '\(find)' στο filename.")
        }
        guard entries.count <= 5_000 else {
            return .reply("Το batch περιέχει \(entries.count) renames και υπερβαίνει το safety limit των 5000 ανά operation.")
        }

        let payload = BatchRenamePayload(folderPath: folder.path, entries: entries)
        let data = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: data, encoding: .utf8) else {
            return .reply("Απέτυχε η κωδικοποίηση του batch rename proposal.")
        }

        let preview = entries.prefix(12).map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
        let remaining = entries.count > 12 ? "\n… +\(entries.count - 12) more" : ""

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Batch rename \(entries.count) αρχείων",
            reasoning: "Το rename plan υπολογίστηκε deterministic από το πραγματικό folder listing και πέρασε collision checks πριν ζητηθεί approval.",
            expectedImpact: "\(entries.count) filenames θα αλλάξουν μέσα μόνο στον εγκεκριμένο φάκελο.\n\nPREVIEW\n\(preview)\(remaining)",
            riskLevel: .medium,
            payload: payloadText,
            filename: nil,
            location: folder.path
        ))
    }

    #if os(macOS)
    private func executeRenameBatch(_ payload: BatchRenamePayload, folder: URL) throws -> (renamed: Int, skipped: Int) {
        let manager = FileManager.default

        // Revalidate the entire plan before the first mutation. This prevents
        // partial execution caused by obvious collisions or missing sources.
        for entry in payload.entries {
            let source = folder.appendingPathComponent(entry.from)
            let target = folder.appendingPathComponent(entry.to)
            guard manager.fileExists(atPath: source.path) else { throw FilesystemError.sourceChanged(entry.from) }
            guard !manager.fileExists(atPath: target.path) else { throw FilesystemError.collision(entry.to) }
        }

        var renamed = 0
        for entry in payload.entries {
            let source = folder.appendingPathComponent(entry.from)
            let target = folder.appendingPathComponent(entry.to)
            try manager.moveItem(at: source, to: target)
            renamed += 1
        }
        return (renamed, 0)
    }
    #endif
}
