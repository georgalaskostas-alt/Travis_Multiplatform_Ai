import Foundation

/// Small thread-safe projection of AI usage history for hot-path routing.
/// The persistent source of truth remains AIUsageLedger; this registry only
/// exposes workload/model utility without requiring MainActor access in the
/// synchronous AIModelRouter.
final class AIAdaptiveRoutingRegistry: @unchecked Sendable {
    static let shared = AIAdaptiveRoutingRegistry()

    struct Metric: Hashable {
        let requestCount: Int
        let successRate: Double
        let averageLatencyMilliseconds: Double
        let averageKnownCostUSD: Double?

        var utilityScore: Double {
            let reliability = successRate * 100
            let latencyPenalty = min(30, averageLatencyMilliseconds / 1_000)
            let costPenalty = averageKnownCostUSD.map { min(30, $0 * 300) } ?? 10
            return reliability - latencyPenalty - costPenalty
        }
    }

    private let lock = NSLock()
    private var metrics: [String: Metric] = [:]

    private init() {}

    func rebuild(from records: [AIUsageRecord]) {
        let grouped = Dictionary(grouping: records) { record in
            Self.key(provider: record.provider, model: record.model, workload: record.workload)
        }

        var rebuilt: [String: Metric] = [:]
        rebuilt.reserveCapacity(grouped.count)

        for (key, values) in grouped where !values.isEmpty {
            let successes = values.filter(\.succeeded).count
            let averageLatency = Double(values.reduce(0) { $0 + $1.latencyMilliseconds }) / Double(values.count)
            let knownCosts = values.compactMap(\.estimatedCostUSD)
            let averageCost = knownCosts.isEmpty ? nil : knownCosts.reduce(0, +) / Double(knownCosts.count)
            rebuilt[key] = Metric(
                requestCount: values.count,
                successRate: Double(successes) / Double(values.count),
                averageLatencyMilliseconds: averageLatency,
                averageKnownCostUSD: averageCost
            )
        }

        lock.lock()
        metrics = rebuilt
        lock.unlock()
    }

    func metric(provider: AIProvider, model: String, workload: AIWorkloadClass) -> Metric? {
        let key = Self.key(provider: provider, model: model, workload: workload)
        lock.lock()
        let value = metrics[key]
        lock.unlock()
        return value
    }

    private static func key(provider: AIProvider, model: String, workload: AIWorkloadClass) -> String {
        "\(provider.rawValue)::\(model.lowercased())::\(workload.rawValue)"
    }
}
