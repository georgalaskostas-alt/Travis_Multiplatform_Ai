import Foundation

/// Durable local snapshot store for autonomous runtime state.
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
        let baseURL = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("TRAVIS/Runtime", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("agent-tasks-v1.json")
    }

    func load() throws -> [AgentTask] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == schemaVersion else { throw AgentTaskStoreError.unsupportedSchema(snapshot.schemaVersion) }
        return snapshot.tasks
    }

    func loadForStatusBriefing() -> [AgentTask] { (try? load()) ?? [] }

    func save(_ tasks: [AgentTask]) throws {
        let snapshot = Snapshot(schemaVersion: schemaVersion, savedAt: Date(), tasks: tasks)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: storeURL, options: .atomic)
    }

    @discardableResult
    func deleteTask(id: UUID, activeTaskIDs: Set<UUID> = []) throws -> Bool {
        guard !activeTaskIDs.contains(id) else { throw AgentTaskStoreError.taskIsActive(id) }
        var tasks = try load()
        let originalCount = tasks.count
        tasks.removeAll { $0.id == id }
        guard tasks.count != originalCount else { return false }
        try save(tasks)
        return true
    }

    @discardableResult
    func deleteAll(excluding activeTaskIDs: Set<UUID> = []) throws -> Int {
        let tasks = try load()
        let remaining = tasks.filter { activeTaskIDs.contains($0.id) }
        let deleted = tasks.count - remaining.count
        if deleted > 0 { try save(remaining) }
        return deleted
    }
}

enum AgentTaskStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case taskIsActive(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported autonomous runtime snapshot schema: \(version)."
        case .taskIsActive(let id): return "Cannot delete active task \(id.uuidString.prefix(8)). Pause or cancel it first."
        }
    }
}
