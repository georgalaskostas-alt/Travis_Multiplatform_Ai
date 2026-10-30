import Foundation

@MainActor
final class LocalProjectWorkspaceCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "local_project_workspace"
    let name = "Local Project Workspace"
    let capabilityDescription = "Reads project workspace state locally and safely appends project milestones to a dedicated TRAVIS project log."
    let keywords = ["project status", "project milestone", "project log", "workspace status", "κατασταση project", "οροσημο project", "ιστορικο project"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let locations: FileLocationService
    private let maxFiles = 20_000
    private let maxMilestoneBytes = 100_000

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
                requiresExplicitApproval: false,
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        invocation.operation == "append_milestone"
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        invocation.operation == "append_milestone" ? .medium : .low
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_project_workspace capability χρησιμοποιεί structured project path για status και milestone logging.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id, let rawPath = invocation.arguments["path"] else {
            return .reply("Χρειάζομαι ακριβές project path.")
        }

        switch invocation.operation {
        case "status":
            guard let scoped = locations.resolveExistingPath(rawPath) else {
                return .reply("Το project δεν είναι διαθέσιμο μέσα στο εγκεκριμένο filesystem scope.")
            }
            defer { scoped.stopAccessing() }
            return .reply(StructuredStepOutputCodec.append(values: ["text": try statusReport(root: scoped.url)], to: try statusReport(root: scoped.url)))

        case "append_milestone":
            guard let milestone = invocation.arguments["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !milestone.isEmpty,
                  Data(milestone.utf8).count <= maxMilestoneBytes,
                  let scoped = locations.resolveExistingPath(rawPath) else {
                return .reply("Χρειάζομαι project path και milestone text έως 100 KB.")
            }
            defer { scoped.stopAccessing() }
            let logURL = scoped.url.appendingPathComponent("TRAVIS_PROJECT_LOG.md")
            let payload = Payload(path: scoped.url.path, milestone: milestone)
            let data = try JSONEncoder().encode(payload)
            guard let payloadText = String(data: data, encoding: .utf8) else { return .reply("Απέτυχε η προετοιμασία του milestone.") }
            return .proposal(ProposedAction(
                capabilityId: id,
                summary: "Append project milestone",
                reasoning: "Θα προστεθεί νέο timestamped milestone μόνο στο TRAVIS_PROJECT_LOG.md του συγκεκριμένου project.",
                expectedImpact: "Θα ενημερωθεί ή θα δημιουργηθεί: \(logURL.path). Δεν τροποποιείται κανένα άλλο project file.",
                riskLevel: .medium,
                payload: payloadText,
                filename: "TRAVIS_PROJECT_LOG.md",
                location: scoped.url.path
            ))

        default:
            return .reply("Unsupported project-workspace operation.")
        }
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payloadText = action.payload,
              let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              Data(payload.milestone.utf8).count <= maxMilestoneBytes,
              let scoped = locations.resolveExistingPath(payload.path) else { return }
        defer { scoped.stopAccessing() }

        let logURL = scoped.url.appendingPathComponent("TRAVIS_PROJECT_LOG.md")
        let entry = "\n## \(Self.iso8601.string(from: Date()))\n\n\(payload.milestone)\n"
        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try ("# TRAVIS Project Log\n" + entry).write(to: logURL, atomically: true, encoding: .utf8)
            }
            PersistenceService.shared.saveFile(filename: "TRAVIS_PROJECT_LOG.md", path: logURL.path, capabilityId: id)
            onExecutionUpdate?("✅ Project milestone recorded: \(logURL.path)")
        } catch {
            onExecutionUpdate?("❌ Project milestone failed: \(error.localizedDescription)")
        }
    }

    private struct Payload: Codable {
        let path: String
        let milestone: String
    }

    private func statusReport(root: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "PROJECT STATUS\n\nThe requested path is not a directory."
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return "PROJECT STATUS\n\nUnable to enumerate project workspace."
        }

        var count = 0
        var bytes: Int64 = 0
        var newest: (URL, Date)?
        var topLevel: Set<String> = []
        for case let url as URL in enumerator {
            if count >= maxFiles { break }
            let relative = relativePath(url, root: root)
            if let first = relative.split(separator: "/").first { topLevel.insert(String(first)) }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate, newest == nil || modified > newest!.1 { newest = (url, modified) }
        }

        let logURL = root.appendingPathComponent("TRAVIS_PROJECT_LOG.md")
        let hasLog = FileManager.default.fileExists(atPath: logURL.path)
        let newestText = newest.map { "\(relativePath($0.0, root: root)) | \(Self.iso8601.string(from: $0.1))" } ?? "none"
        let children = topLevel.sorted().prefix(30).joined(separator: ", ")
        return """
        PROJECT STATUS

        root: \(root.path)
        files: \(count)
        total_bytes: \(bytes)
        project_log: \(hasLog ? "present" : "not created yet")
        newest_file: \(newestText)
        top_level: \(children.isEmpty ? "(empty)" : children)
        """
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    private static let iso8601 = ISO8601DateFormatter()
}
