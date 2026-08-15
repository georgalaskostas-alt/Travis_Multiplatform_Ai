import Foundation

/// Durable local snapshot store for autonomous runtime state.
///
/// Runtime state is intentionally kept separate from the existing CloudKit
/// SwiftData schema for now. AgentTask is already Codable, so Runtime v1 can
/// gain crash/relaunch recovery without coupling its evolving execution schema
/// to user-facing synced models.
///
/// Writes use Data.write(.atomic): a completed snapshot replaces the previous
/// one atomically instead of exposing a partially-written JSON document.
final class AgentTaskStore {
    static let shared = AgentTaskStore()

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var tasks: [AgentTask]
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

        let directory = baseURL.appendingPathComponent("TRAVIS/Runtime", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("agent-tasks-v1.json")
    }

    func load() throws -> [AgentTask] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)

        guard snapshot.schemaVersion == schemaVersion else {
            throw AgentTaskStoreError.unsupportedSchema(snapshot.schemaVersion)
        }

        return snapshot.tasks
    }

    func save(_ tasks: [AgentTask]) throws {
        let snapshot = Snapshot(
            schemaVersion: schemaVersion,
            savedAt: Date(),
            tasks: tasks
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: storeURL, options: .atomic)
    }
}

enum AgentTaskStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported autonomous runtime snapshot schema: \(version)."
        }
    }
}
