import Foundation
import Observation

/// Measures work resolved locally before a provider call is needed. These are
/// operational counters, not billing estimates; they deliberately never claim
/// a dollar saving that cannot be proven from a skipped provider request.
@MainActor
@Observable
final class LocalIntelligenceMetrics {
    static let shared = LocalIntelligenceMetrics()

    enum EventKind: String, Codable, CaseIterable, Hashable {
        case deterministicIntent
        case deterministicSchedule
        case deterministicFilesystemParse
        case deterministicSkillPlan
        case structuredCapabilityExecution
        case learnedCapabilityRoute
    }

    struct Counters: Codable, Hashable {
        var values: [String: Int] = [:]
        var total: Int { values.values.reduce(0, +) }
    }

    private struct Snapshot: Codable {
        var version: Int
        var counters: Counters
        var updatedAt: Date
    }

    private(set) var counters = Counters()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("local-intelligence-metrics-v1.json")
        reload()
    }

    func record(_ event: EventKind, count: Int = 1) {
        guard count > 0 else { return }
        counters.values[event.rawValue, default: 0] += count
        persist()
    }

    func count(_ event: EventKind) -> Int {
        counters.values[event.rawValue, default: 0]
    }

    func diagnosticReport() -> String {
        let rows = EventKind.allCases.map {
            "\($0.rawValue): \(count($0))"
        }.joined(separator: "\n")

        return """
        TRAVIS LOCAL INTELLIGENCE

        LOCAL RESOLUTIONS / BYPASSES
        \(counters.total)

        BY TYPE
        \(rows)

        These counters represent local deterministic/learned decisions that avoided or shortened an AI-routing/planning stage. They are not converted to dollar savings unless a provider request and verified pricing would otherwise be known.
        """
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return }
        counters = snapshot.counters
    }

    private func persist() {
        let snapshot = Snapshot(version: 1, counters: counters, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
