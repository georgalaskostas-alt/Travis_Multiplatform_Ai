import Foundation

@MainActor
final class AdvancedFilesystemCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "advanced_filesystem"
    let name = "Advanced Filesystem"
    let capabilityDescription = "Scoped create-folder, copy, move, delete and organize operations with deterministic previews and approval-gated mutations."
    let keywords: [String] = [
        "move files", "copy files", "delete files", "create folder", "organize files",
        "μετακινησε αρχεια", "μετακίνησε αρχεία", "αντιγραψε αρχεια", "αντίγραψε αρχεία",
        "διεγραψε αρχεια", "διέγραψε αρχεία", "δημιουργησε φακελο", "δημιούργησε φάκελο",
        "οργανωσε αρχεια", "οργάνωσε αρχεία"
    ]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let locations: FileLocationService

    init(aiService: AIService = .shared, locations: FileLocationService? = nil) {
        self.aiService = aiService
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
                timeoutSeconds: 120,
                maxAttempts: 2
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        #if !os(macOS)
        return .reply("Το advanced filesystem capability είναι διαθέσιμο προς το παρόν στο macOS build του TRAVIS.")
        #else
        let intent = try await parse(command: command, recentHistory: recentHistory)
        return try buildOutcome(for: intent)
        #endif
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard invocation.capabilityId == id else {
            return .reply("Το structured invocation δεν ανήκει στο advanced_filesystem capability.")
        }

        #if !os(macOS)
        return .reply("Το advanced filesystem capability είναι διαθέσιμο προς το παρόν στο macOS build του TRAVIS.")
        #else
        let intent = Intent(
            operation: invocation.operation,
            sourcePath: invocation.arguments["sourcePath"] ?? invocation.arguments["path"],
            destinationPath: invocation.arguments["destinationPath"],
            folderName: invocation.arguments["folderName"],
            matchExtension: invocation.arguments["matchExtension"],
            names: invocation.arguments["names"]?.split(separator: "|").map(String.init) ?? []
        )
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)
        return try buildOutcome(for: intent)
        #endif
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MutationPayload.self, from: data) else { return }

        #if os(macOS)
        do {
            let result = try execute(payload)
            onExecutionUpdate?("✅ Filesystem operation completed: \(result)")
        } catch {
            onExecutionUpdate?("❌ Filesystem operation stopped safely: \(error.localizedDescription)")
        }
        #endif
    }

    private struct Intent: Decodable {
        let operation: String
        let sourcePath: String?
        let destinationPath: String?
        let folderName: String?
        let matchExtension: String?
        let names: [String]
    }

    private struct MutationPayload: Codable {
        let operation: String
        let sourcePath: String
        let destinationPath: String?
        let folderName: String?
        let names: [String]
    }

    private enum FileOpError: LocalizedError {
        case invalidScope(String)
        case invalidOperation(String)
        case collision(String)
        case missingSource(String)
        case unsafeName(String)

        var errorDescription: String? {
            switch self {
            case .invalidScope(let path): return "Το path δεν είναι διαθέσιμο μέσα στο εγκεκριμένο security scope: \(path)"
            case .invalidOperation(let op): return "Μη υποστηριζόμενη filesystem operation: \(op)"
            case .collision(let name): return "Υπάρχει ήδη destination item με όνομα \(name)."
            case .missingSource(let name): return "Το source item λείπει: \(name)."
            case .unsafeName(let name): return "Μη ασφαλές filename/folder name: \(name)."
            }
        }
    }

    private func parse(command: String, recentHistory: [ChatMessage]) async throws -> Intent {
        let prompt = """
        Parse a scoped filesystem request for TRAVIS.
        Allowed operations ONLY: none, create_folder, copy, move, delete, organize_extension.
        sourcePath and destinationPath must be exact paths supplied by the user. Never invent paths.
        folderName is a single new folder name for create_folder.
        matchExtension is an extension without a leading dot, e.g. png.
        names is an array of exact filenames when the user explicitly names files; otherwise [] means all matching files for matchExtension.
        organize_extension means move files with matchExtension into destinationPath.
        Return JSON only with this exact schema:
        {"operation":"none","sourcePath":null,"destinationPath":null,"folderName":null,"matchExtension":null,"names":[]}

        RECENT CONTEXT
        \(recentHistory.suffix(4).promptTranscript)

        USER REQUEST
        \(command)
        """
        let raw = try await aiService.generateText(
            prompt: prompt,
            maxTokens: 500,
            context: AIInvocationContext(workload: .classification, capabilityId: id, operation: "filesystem.parse")
        )
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Intent.self, from: data) else {
            return Intent(operation: "none", sourcePath: nil, destinationPath: nil, folderName: nil, matchExtension: nil, names: [])
        }
        return decoded
    }

    #if os(macOS)
    private func buildOutcome(for intent: Intent) throws -> CapabilityOutcome {
        guard intent.operation != "none" else {
            return .reply("Δεν εντόπισα αρκετά συγκεκριμένη advanced filesystem εργασία. Χρειάζομαι σαφή operation και πραγματικό path.")
        }
        guard let sourcePath = intent.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !sourcePath.isEmpty else {
            return .reply("Χρειάζομαι συγκεκριμένο source folder path.")
        }

        ensureScopePermission()
        guard let source = locations.resolveExistingPath(sourcePath) else { throw FileOpError.invalidScope(sourcePath) }
        defer { source.stopAccessing() }

        let selectedNames = try selectNames(intent: intent, sourceFolder: source.url)
        let payload: MutationPayload
        let summary: String
        let preview: String

        switch intent.operation {
        case "create_folder":
            guard let folderName = intent.folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
                return .reply("Χρειάζομαι συγκεκριμένο όνομα φακέλου.")
            }
            try validateSimpleName(folderName)
            let target = source.url.appendingPathComponent(folderName)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOpError.collision(folderName) }
            payload = MutationPayload(operation: intent.operation, sourcePath: source.url.path, destinationPath: nil, folderName: folderName, names: [])
            summary = "Create folder \(folderName)"
            preview = target.path

        case "copy", "move", "organize_extension":
            guard let destinationPath = intent.destinationPath?.trimmingCharacters(in: .whitespacesAndNewlines), !destinationPath.isEmpty,
                  let destination = locations.resolveExistingPath(destinationPath) else {
                throw FileOpError.invalidScope(intent.destinationPath ?? "<missing>")
            }
            defer { destination.stopAccessing() }
            try preflightTargets(names: selectedNames, destination: destination.url)
            payload = MutationPayload(operation: intent.operation, sourcePath: source.url.path, destinationPath: destination.url.path, folderName: nil, names: selectedNames)
            summary = "\(intent.operation) \(selectedNames.count) filesystem items"
            preview = previewLines(names: selectedNames, source: source.url, destination: destination.url)

        case "delete":
            guard !selectedNames.isEmpty else { return .reply("Δεν βρέθηκαν αρχεία που να ταιριάζουν στο delete request.") }
            payload = MutationPayload(operation: intent.operation, sourcePath: source.url.path, destinationPath: nil, folderName: nil, names: selectedNames)
            summary = "Delete \(selectedNames.count) filesystem items"
            preview = selectedNames.prefix(15).joined(separator: "\n")

        default:
            throw FileOpError.invalidOperation(intent.operation)
        }

        guard selectedNames.count <= 5_000 || intent.operation == "create_folder" else {
            return .reply("Το batch υπερβαίνει το safety limit των 5000 items.")
        }

        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else {
            return .reply("Απέτυχε η προετοιμασία του filesystem proposal.")
        }

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: summary,
            reasoning: "Το operation προετοιμάστηκε πάνω στο πραγματικό security-scoped filesystem και πέρασε preflight checks πριν την έγκριση.",
            expectedImpact: preview,
            riskLevel: intent.operation == "delete" ? .high : .medium,
            payload: payloadText,
            filename: nil,
            location: source.url.path
        ))
    }

    private func ensureScopePermission() {
        if !locations.hasHomeDirectoryAccess {
            _ = locations.requestHomeDirectoryAccess()
        }
    }

    private func selectNames(intent: Intent, sourceFolder: URL) throws -> [String] {
        if !intent.names.isEmpty {
            for name in intent.names { try validateSimpleName(name) }
            return intent.names
        }
        guard let rawExtension = intent.matchExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), !rawExtension.isEmpty else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: sourceFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true,
                  url.pathExtension.caseInsensitiveCompare(rawExtension) == .orderedSame else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    private func validateSimpleName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { throw FileOpError.unsafeName(name) }
    }

    private func preflightTargets(names: [String], destination: URL) throws {
        for name in names {
            try validateSimpleName(name)
            let target = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { throw FileOpError.collision(name) }
        }
    }

    private func previewLines(names: [String], source: URL, destination: URL) -> String {
        let rows = names.prefix(15).map { "\(source.appendingPathComponent($0).path) → \(destination.appendingPathComponent($0).path)" }
        let suffix = names.count > 15 ? "\n… +\(names.count - 15) more" : ""
        return rows.joined(separator: "\n") + suffix
    }

    private func execute(_ payload: MutationPayload) throws -> String {
        guard let source = locations.resolveExistingPath(payload.sourcePath) else { throw FileOpError.invalidScope(payload.sourcePath) }
        defer { source.stopAccessing() }

        switch payload.operation {
        case "create_folder":
            guard let folderName = payload.folderName else { throw FileOpError.invalidOperation(payload.operation) }
            try validateSimpleName(folderName)
            let target = source.url.appendingPathComponent(folderName)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOpError.collision(folderName) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return "created folder \(target.path)"

        case "copy", "move", "organize_extension":
            guard let destinationPath = payload.destinationPath,
                  let destination = locations.resolveExistingPath(destinationPath) else { throw FileOpError.invalidScope(payload.destinationPath ?? "<missing>") }
            defer { destination.stopAccessing() }
            try preflightTargets(names: payload.names, destination: destination.url)
            var completed = 0
            for name in payload.names {
                let from = source.url.appendingPathComponent(name)
                let to = destination.url.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: from.path) else { throw FileOpError.missingSource(name) }
                if payload.operation == "copy" {
                    try FileManager.default.copyItem(at: from, to: to)
                } else {
                    try FileManager.default.moveItem(at: from, to: to)
                }
                completed += 1
            }
            return "\(payload.operation) completed for \(completed) items"

        case "delete":
            var completed = 0
            for name in payload.names {
                try validateSimpleName(name)
                let item = source.url.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: item.path) else { throw FileOpError.missingSource(name) }
                try FileManager.default.removeItem(at: item)
                completed += 1
            }
            return "deleted \(completed) items"

        default:
            throw FileOpError.invalidOperation(payload.operation)
        }
    }
    #endif
}
