import Foundation

final class DeferredWorkStore {
    static let shared = DeferredWorkStore()
    private let schemaVersion = 1

    private struct Envelope: Codable {
        var version: Int
        var items: [DeferredWorkItem]
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("deferred-work-v1.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> [DeferredWorkItem] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == schemaVersion else {
            throw DeferredWorkStoreError.unsupportedSchema(envelope.version)
        }
        return envelope.items
    }

    func save(_ items: [DeferredWorkItem]) throws {
        let data = try encoder.encode(Envelope(version: schemaVersion, items: items))
        let temporaryURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }
}


enum DeferredWorkStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported deferred work snapshot schema: \(version)."
        }
    }
}
