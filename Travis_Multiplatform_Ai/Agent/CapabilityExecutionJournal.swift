import Foundation

final class CapabilityExecutionJournal {
    static let shared = CapabilityExecutionJournal()

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var records: [CapabilityExecutionRecord]
    }

    private let schemaVersion = 1
    private let fileManager: FileManager
    private let storeURL: URL
    private let maxRecords = 500

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent("TRAVIS/Observability", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("capability-executions-v1.json")
    }

    func load() -> [CapabilityExecutionRecord] {
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == schemaVersion else { return [] }
        return snapshot.records.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    func begin(
        capabilityId: String,
        command: String,
        taskId: UUID? = nil,
        projectId: UUID? = nil
    ) -> UUID {
        var records = load()
        let record = CapabilityExecutionRecord(
            capabilityId: capabilityId,
            commandSummary: command,
            taskId: taskId,
            projectId: projectId
        )
        records.insert(record, at: 0)
        save(Array(records.prefix(maxRecords)))
        return record.id
    }

    func finish(
        recordId: UUID,
        status: CapabilityExecutionRecord.Status,
        resultSummary: String? = nil,
        artifacts: [String] = [],
        error: String? = nil
    ) {
        var records = load()
        guard let index = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[index].finishedAt = Date()
        records[index].status = status
        records[index].resultSummary = resultSummary.map { String($0.prefix(1200)) }
        records[index].artifactPaths = Array(artifacts.prefix(20))
        records[index].errorDescription = error.map { String($0.prefix(1200)) }
        save(Array(records.prefix(maxRecords)))
    }

    func diagnosticReport(limit: Int = 20) -> String {
        let records = load().prefix(max(1, min(limit, 100)))
        guard !records.isEmpty else { return "CAPABILITY EXECUTION LOG\n\nκανένα record" }
        let formatter = ISO8601DateFormatter()
        let rows = records.map { record in
            let timestamp = formatter.string(from: record.startedAt)
            let task = record.taskId.map { " task:\($0.uuidString.prefix(8))" } ?? ""
            let project = record.projectId.map { " project:\($0.uuidString.prefix(8))" } ?? ""
            return "[\(timestamp)] \(record.capabilityId) [\(record.status.rawValue)]\(task)\(project) — \(record.commandSummary.prefix(120))"
        }.joined(separator: "\n")
        return "CAPABILITY EXECUTION LOG\n\n\(rows)"
    }

    private func save(_ records: [CapabilityExecutionRecord]) {
        let snapshot = Snapshot(schemaVersion: schemaVersion, savedAt: Date(), records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
