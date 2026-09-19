import Foundation

/// In-memory health projection derived from the durable AI usage ledger.
/// It prevents repeatedly selecting a model/provider combination that is
/// currently failing. This is a routing optimization only; it never changes
/// persisted provider credentials or model configuration.
final class AIModelCircuitBreaker: @unchecked Sendable {
    static let shared = AIModelCircuitBreaker()

    struct Health: Hashable {
        var recentAttempts: Int
        var recentFailures: Int
        var consecutiveFailures: Int
        var temporarilyDeprioritized: Bool
    }

    private struct Key: Hashable {
        var provider: AIProvider
        var model: String
        var workload: AIWorkloadClass
    }

    private let lock = NSLock()
    private var health: [Key: Health] = [:]

    private init() {}

    func rebuild(from records: [AIUsageRecord], now: Date = Date()) {
        let windowStart = now.addingTimeInterval(-15 * 60)
        let recent = records.filter { $0.timestamp >= windowStart }
        let grouped = Dictionary(grouping: recent) { record in
            Key(provider: record.provider, model: record.model.lowercased(), workload: record.workload)
        }

        var rebuilt: [Key: Health] = [:]
        for (key, values) in grouped {
            let sorted = values.sorted { $0.timestamp < $1.timestamp }
            let failures = sorted.filter { !$0.succeeded }.count
            var consecutiveFailures = 0
            for record in sorted.reversed() {
                if record.succeeded { break }
                consecutiveFailures += 1
            }

            // Require repeated evidence before changing routing. One transient
            // failure must not blacklist a model.
            let deprioritized = consecutiveFailures >= 3 ||
                (sorted.count >= 5 && Double(failures) / Double(sorted.count) >= 0.60)

            rebuilt[key] = Health(
                recentAttempts: sorted.count,
                recentFailures: failures,
                consecutiveFailures: consecutiveFailures,
                temporarilyDeprioritized: deprioritized
            )
        }

        lock.lock()
        health = rebuilt
        lock.unlock()
    }

    func status(provider: AIProvider, model: String, workload: AIWorkloadClass) -> Health? {
        let key = Key(provider: provider, model: model.lowercased(), workload: workload)
        lock.lock()
        let value = health[key]
        lock.unlock()
        return value
    }

    func shouldDeprioritize(provider: AIProvider, model: String, workload: AIWorkloadClass) -> Bool {
        status(provider: provider, model: model, workload: workload)?.temporarilyDeprioritized == true
    }
}
