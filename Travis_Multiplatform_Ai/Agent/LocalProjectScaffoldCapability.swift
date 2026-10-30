import Foundation

@MainActor
final class LocalProjectScaffoldCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "local_project_scaffold"
    let name = "Local Project Scaffold"
    let capabilityDescription = "Creates a new project workspace folder with a predictable starter structure and README, using one approval and no overwrite."
    let keywords = ["project scaffold", "project workspace", "starter project", "create project folder", "σκελετο project", "φτιαξε project", "δημιουργησε project"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let locations: FileLocationService
    private let maxFolders = 20

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
        .reply("Το local_project_scaffold capability χρειάζεται structured parent directory, project name και προαιρετικά starter folders.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard invocation.capabilityId == id, invocation.operation == "create_scaffold" else {
            return .reply("Unsupported project-scaffold operation.")
        }
        guard let parentPath = invocation.arguments["parentPath"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentPath.isEmpty,
              let projectName = invocation.arguments["projectName"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSafeSimpleName(projectName) else {
            return .reply("Χρειάζομαι ακριβές parent path και ασφαλές project name.")
        }

        let requestedFolders = invocation.arguments["folders"]?
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let folders = requestedFolders.isEmpty ? ["docs", "data", "output", "notes"] : requestedFolders
        guard folders.count <= maxFolders, folders.allSatisfy(isSafeSimpleName) else {
            return .reply("Τα starter folders πρέπει να είναι έως \(maxFolders) ασφαλή απλά ονόματα.")
        }

        guard let parent = locations.resolveSaveDirectory(for: parentPath) else {
            return .reply("Ο parent folder δεν είναι μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { parent.stopAccessing() }

        let projectURL = parent.url.appendingPathComponent(projectName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: projectURL.path) else {
            return .reply("Υπάρχει ήδη project folder: \(projectURL.path). Δεν θα γίνει overwrite.")
        }

        let readme = invocation.arguments["readme"] ?? defaultReadme(projectName: projectName, folders: folders)
        let payload = Payload(parentPath: parent.url.path, projectName: projectName, folders: folders, readme: readme)
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else {
            return .reply("Απέτυχε η προετοιμασία του project scaffold.")
        }

        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Create project workspace \(projectName)",
            reasoning: "Θα δημιουργηθεί μόνο νέο project folder με starter structure. Δεν επιτρέπεται overwrite υπάρχοντος project.",
            expectedImpact: "Θα δημιουργηθεί \(projectURL.path) με README.md και folders: \(folders.joined(separator: ", ")).",
            riskLevel: .medium,
            payload: payloadText,
            filename: projectName,
            location: parent.url.path
        ))
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isSafeSimpleName(payload.projectName),
              payload.folders.count <= maxFolders,
              payload.folders.allSatisfy(isSafeSimpleName),
              let parent = locations.resolveSaveDirectory(for: payload.parentPath) else { return }
        defer { parent.stopAccessing() }

        let projectURL = parent.url.appendingPathComponent(payload.projectName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: projectURL.path) else {
            onExecutionUpdate?("❌ Project creation stopped: target folder already exists.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
            do {
                for folder in payload.folders {
                    try FileManager.default.createDirectory(
                        at: projectURL.appendingPathComponent(folder, isDirectory: true),
                        withIntermediateDirectories: false
                    )
                }
                let readmeURL = projectURL.appendingPathComponent("README.md")
                try payload.readme.write(to: readmeURL, atomically: true, encoding: .utf8)
                PersistenceService.shared.saveFile(filename: payload.projectName, path: projectURL.path, capabilityId: id)
                onExecutionUpdate?("✅ Project workspace created: \(projectURL.path)")
            } catch {
                try? FileManager.default.removeItem(at: projectURL)
                throw error
            }
        } catch {
            onExecutionUpdate?("❌ Project creation stopped safely: \(error.localizedDescription)")
        }
    }

    private struct Payload: Codable {
        let parentPath: String
        let projectName: String
        let folders: [String]
        let readme: String
    }

    private func defaultReadme(projectName: String, folders: [String]) -> String {
        let rows = folders.map { "- `\($0)/`" }.joined(separator: "\n")
        return """
        # \(projectName)

        Project workspace created by TRAVIS.

        ## Structure
        \(rows)

        ## Status
        Initial workspace created. Add project-specific decisions and deliverables as the work progresses.
        """
    }

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("|")
    }
}
