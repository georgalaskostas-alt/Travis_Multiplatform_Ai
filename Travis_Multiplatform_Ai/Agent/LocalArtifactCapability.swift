import Foundation

@MainActor
final class LocalArtifactCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "local_artifact"
    let name = "Local Artifact"
    let capabilityDescription = "Creates new local text/data artifacts from exact structured content with approval and no overwrite."
    let keywords = ["save result", "save text", "write file", "αποθήκευσε αποτέλεσμα", "δημιούργησε αρχείο"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let locations: FileLocationService
    private let maxBytes = 20_000_000
    private static let allowedExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "yaml", "yml", "xml"]

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
                declaredEffects: [.localMutation],
                permissionKeys: ["file_save"],
                requiresExplicitApproval: true,
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { true }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .medium }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_artifact capability δέχεται structured content και ακριβή destination ώστε να μη μαντεύει τι ή πού θα γράψει.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id, invocation.operation == "write_new" else {
            return .reply("Unsupported local artifact operation.")
        }
        guard let directory = invocation.arguments["directory"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty,
              let filename = invocation.arguments["filename"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSafeFilename(filename),
              let text = invocation.arguments["text"] else {
            return .reply("Χρειάζομαι ακριβές directory, ασφαλές filename και content.")
        }
        guard let scoped = locations.resolveSaveDirectory(for: directory) else {
            return .reply("Ο destination folder δεν είναι μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { scoped.stopAccessing() }

        let target = scoped.url.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .reply("Υπάρχει ήδη αρχείο στο destination: \(target.path). Δεν θα γίνει overwrite.")
        }
        let bytes = Data(text.utf8)
        guard bytes.count <= maxBytes else { return .reply("Το παραγόμενο αρχείο υπερβαίνει το safety limit των 20 MB.") }

        let payload = Payload(directory: scoped.url.path, filename: filename, text: text)
        let data = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: data, encoding: .utf8) else { return .reply("Απέτυχε η προετοιμασία του artifact.") }

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Create artifact \(filename)",
            reasoning: "Το content έχει ήδη παραχθεί. Η δημιουργία νέου αρχείου απαιτεί έγκριση και δεν επιτρέπεται overwrite.",
            expectedImpact: "Θα δημιουργηθεί νέο αρχείο: \(target.path) (\(bytes.count) bytes)",
            riskLevel: .medium,
            payload: payloadText,
            filename: filename,
            location: scoped.url.path
        ))
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isSafeFilename(payload.filename),
              Data(payload.text.utf8).count <= maxBytes,
              let scoped = locations.resolveSaveDirectory(for: payload.directory) else { return }
        defer { scoped.stopAccessing() }

        let target = scoped.url.appendingPathComponent(payload.filename)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            onExecutionUpdate?("❌ Artifact creation stopped: target already exists.")
            return
        }
        do {
            try Data(payload.text.utf8).write(to: target, options: [.atomic])
            PersistenceService.shared.saveFile(filename: payload.filename, path: target.path, capabilityId: id)
            onExecutionUpdate?("✅ Artifact created: \(target.path)")
        } catch {
            onExecutionUpdate?("❌ Artifact creation failed: \(error.localizedDescription)")
        }
    }

    private struct Payload: Codable {
        let directory: String
        let filename: String
        let text: String
    }

    private func isSafeFilename(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"), !value.contains("|") else { return false }
        let ext = (value as NSString).pathExtension.lowercased()
        return Self.allowedExtensions.contains(ext)
    }
}
