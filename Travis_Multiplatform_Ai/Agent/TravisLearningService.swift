import Foundation
import Observation

@MainActor
@Observable
final class TravisLearningService {
    static let shared = TravisLearningService()

    private(set) var totalAIRequests: Int = 0
    private(set) var successfulAIRequests: Int = 0
    private(set) var learnedRoutes: Int = 0
    private(set) var totalTokens: Int = 0
    private(set) var estimatedSpendUSD: Double = 0
    private(set) var bestKnownRoute: String = "Learning"
    private(set) var confidence: Double = 0

    private init() { refresh() }

    func refresh() {
        let records = AIUsageLedger.shared.records
        totalAIRequests = records.count
        successfulAIRequests = records.filter(\.succeeded).count
        totalTokens = records.reduce(0) { $0 + $1.usage.totalTokens }
        estimatedSpendUSD = records.compactMap(\.estimatedCostUSD).reduce(0, +)

        let groups = Dictionary(grouping: records) {
            "\($0.provider.rawValue)|\($0.model)|\($0.workload.rawValue)"
        }
        learnedRoutes = groups.count

        let candidates = groups.compactMap { key, values -> (String, Double)? in
            guard values.count >= 2 else { return nil }
            let successes = Double(values.filter(\.succeeded).count) / Double(values.count)
            let avgLatency = Double(values.reduce(0) { $0 + $1.latencyMilliseconds }) / Double(values.count)
            let knownCosts = values.compactMap(\.estimatedCostUSD)
            let avgCost = knownCosts.isEmpty ? 0 : knownCosts.reduce(0, +) / Double(knownCosts.count)
            let score = successes * 100 - min(25, avgLatency / 1000) - min(25, avgCost * 250)
            return (key, score)
        }

        if let best = candidates.max(by: { $0.1 < $1.1 }) {
            let parts = best.0.split(separator: "|")
            bestKnownRoute = parts.count >= 2 ? "\(parts[0]) · \(parts[1])" : best.0
        } else {
            bestKnownRoute = records.last.map { "\($0.provider.rawValue) · \($0.model)" } ?? "Learning"
        }

        if totalAIRequests == 0 {
            confidence = 0
        } else {
            let reliability = Double(successfulAIRequests) / Double(totalAIRequests)
            let experience = min(1, Double(totalAIRequests) / 50)
            confidence = min(1, reliability * 0.75 + experience * 0.25)
        }
    }

    var successRate: Double {
        guard totalAIRequests > 0 else { return 0 }
        return Double(successfulAIRequests) / Double(totalAIRequests)
    }
}
