import Foundation

@MainActor
struct AIModelPerformanceService {
    struct Score: Hashable {
        let provider: AIProvider
        let model: String
        let workload: AIWorkloadClass
        let requestCount: Int
        let successRate: Double
        let averageLatencyMilliseconds: Double
        let averageTokens: Double
        let averageKnownCostUSD: Double?

        /// Higher is better. Reliability dominates, then latency and cost.
        /// Unknown cost is not treated as zero; it receives no cost bonus.
        var utilityScore: Double {
            let reliability = successRate * 100
            let latencyPenalty = min(30, averageLatencyMilliseconds / 1_000)
            let costPenalty: Double
            if let averageKnownCostUSD {
                costPenalty = min(30, averageKnownCostUSD * 300)
            } else {
                costPenalty = 10
            }
            return reliability - latencyPenalty - costPenalty
        }
    }

    private let ledger: AIUsageLedger

    init(ledger: AIUsageLedger = .shared) {
        self.ledger = ledger
    }

    func scores(workload: AIWorkloadClass? = nil) -> [Score] {
        let eligible = ledger.records.filter { workload == nil || $0.workload == workload }
        let grouped = Dictionary(grouping: eligible) { record in
            "\(record.provider.rawValue)::\(record.model)::\(record.workload.rawValue)"
        }

        return grouped.values.compactMap { values -> Score? in
            guard let first = values.first, !values.isEmpty else { return nil }
            let successCount = values.filter(\.succeeded).count
            let latency = Double(values.reduce(0) { $0 + $1.latencyMilliseconds }) / Double(values.count)
            let tokens = Double(values.reduce(0) { $0 + $1.usage.totalTokens }) / Double(values.count)
            let knownCosts = values.compactMap(\.estimatedCostUSD)
            let averageCost = knownCosts.isEmpty ? nil : knownCosts.reduce(0, +) / Double(knownCosts.count)

            return Score(
                provider: first.provider,
                model: first.model,
                workload: first.workload,
                requestCount: values.count,
                successRate: Double(successCount) / Double(values.count),
                averageLatencyMilliseconds: latency,
                averageTokens: tokens,
                averageKnownCostUSD: averageCost
            )
        }
        .sorted { lhs, rhs in
            if lhs.utilityScore != rhs.utilityScore { return lhs.utilityScore > rhs.utilityScore }
            return lhs.requestCount > rhs.requestCount
        }
    }

    func diagnosticReport() -> String {
        let rows = scores().prefix(30).map { score in
            let cost = score.averageKnownCostUSD.map { String(format: "$%.4f", $0) } ?? "unknown"
            return "\(score.provider.rawValue)/\(score.model) [\(score.workload.rawValue)] n=\(score.requestCount) success=\(Int(score.successRate * 100))% latency=\(Int(score.averageLatencyMilliseconds))ms avgTokens=\(Int(score.averageTokens)) avgCost=\(cost) utility=\(String(format: "%.1f", score.utilityScore))"
        }.joined(separator: "\n")

        return rows.isEmpty
            ? "AI MODEL PERFORMANCE\n\nNo usage records yet."
            : "AI MODEL PERFORMANCE\n\n\(rows)"
    }
}
