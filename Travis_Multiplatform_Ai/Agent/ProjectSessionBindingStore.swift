import Foundation

/// Lightweight durable mapping from chat session -> project workspace.
/// Kept separate from both SwiftData and project schema so session-binding
/// changes never require a CloudKit or project snapshot migration.
@MainActor
final class ProjectSessionBindingStore {
    static let shared = ProjectSessionBindingStore()

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var bindings: [String: UUID]
    }

    private let schemaVersion = 1
    private let fileManager: FileManager
    private let storeURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("TRAVIS/Projects", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("session-project-bindings-v1.json")
    }

    func bind(sessionId: UUID, projectId: UUID) {
        var bindings = loadBindings()
        bindings[sessionId.uuidString] = projectId
        save(bindings)
    }

    func unbind(sessionId: UUID) {
        var bindings = loadBindings()
        bindings.removeValue(forKey: sessionId.uuidString)
        save(bindings)
    }

    func projectId(for sessionId: UUID) -> UUID? {
        loadBindings()[sessionId.uuidString]
    }

    func project(for sessionId: UUID) -> ProjectWorkspace? {
        guard let id = projectId(for: sessionId) else { return nil }
        return ProjectWorkspaceStore.shared.project(id: id)
    }

    private func loadBindings() -> [String: UUID] {
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion else { return [:] }
        return snapshot.bindings
    }

    private func save(_ bindings: [String: UUID]) {
        let snapshot = Snapshot(schemaVersion: schemaVersion, savedAt: Date(), bindings: bindings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
