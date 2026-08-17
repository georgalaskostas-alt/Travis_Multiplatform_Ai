import Foundation
import Observation

@MainActor
@Observable
final class AIUsageLedger {
    static let shared = AIUsageLedger()

    private struct Snapshot: Codable {
        var version: Int
        var records: [AIUsageRecord]
        var pricing: [String: AIModelPricing]
    }

    private(set) var records: [AIUsageRecord] = []
    private(set) var pricing: [String: AIModelPricing] = [:]
    private(set) var persistenceError: String?

    private let maxRecords = 10_000
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("ai-usage-v1.json")
        reload()
    }

    func record(selection: AIModelSelection, context: AIInvocationContext, usage: AITokenUsage, latencyMilliseconds: Int, attempt: Int, succeeded: Bool, errorType: String? = nil) {
        let price = pricing[pricingKey(provider: selection.provider, model: selection.model)]
        let estimatedCost = price?.estimatedCost(for: usage)
        records.append(AIUsageRecord(provider: selection.provider, model: selection.model, tier: selection.tier, context: context, usage: usage, estimatedCostUSD: estimatedCost, latencyMilliseconds: latencyMilliseconds, attempt: attempt, succeeded: succeeded, errorType: errorType))
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        persist()
    }

    func setPricing(provider: AIProvider, model: String, pricing value: AIModelPricing) {
        pricing[pricingKey(provider: provider, model: model)] = value
        recomputeEstimatedCosts()
        persist()
    }

    func removePricing(provider: AIProvider, model: String) {
        pricing.removeValue(forKey: pricingKey(provider: provider, model: model))
        recomputeEstimatedCosts()
        persist()
    }

    func estimatedSpendUSD(since date: Date? = nil, taskId: UUID? = nil) -> Double {
        records.lazy.filter { (date == nil || $0.timestamp >= date!) && (taskId == nil || $0.taskId == taskId) }.compactMap(\.estimatedCostUSD).reduce(0, +)
    }

    func usageSummary(since date: Date? = nil) -> AITokenUsage {
        records.lazy.filter { date == nil || $0.timestamp >= date! }.reduce(into: AITokenUsage()) { result, record in
            result.inputTokens += record.usage.inputTokens
            result.outputTokens += record.usage.outputTokens
            result.cachedInputTokens += record.usage.cachedInputTokens
            result.reasoningTokens += record.usage.reasoningTokens
        }
    }

    func diagnosticReport(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfDay
        let todayUsage = usageSummary(since: startOfDay)
        let monthUsage = usageSummary(since: startOfMonth)
        let todayCost = estimatedSpendUSD(since: startOfDay)
        let monthCost = estimatedSpendUSD(since: startOfMonth)
        let unknownCostRecords = records.filter { $0.estimatedCostUSD == nil && $0.succeeded }.count

        return """
        TRAVIS AI USAGE

        TODAY
        estimated cost: $\(String(format: "%.4f", todayCost))
        input: \(todayUsage.inputTokens)
        cached input: \(todayUsage.cachedInputTokens)
        output: \(todayUsage.outputTokens)
        reasoning: \(todayUsage.reasoningTokens)

        THIS MONTH
        estimated cost: $\(String(format: "%.4f", monthCost))
        input: \(monthUsage.inputTokens)
        cached input: \(monthUsage.cachedInputTokens)
        output: \(monthUsage.outputTokens)
        reasoning: \(monthUsage.reasoningTokens)

        RECORDS
        \(records.count)

        COST-UNKNOWN SUCCESS RECORDS
        \(unknownCostRecords)

        Pricing is estimated only for models with an explicitly configured rate.
        """
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { return }
            records = snapshot.records
            pricing = snapshot.pricing
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func recomputeEstimatedCosts() {
        for index in records.indices {
            let record = records[index]
            let price = pricing[pricingKey(provider: record.provider, model: record.model)]
            records[index].estimatedCostUSD = price?.estimatedCost(for: record.usage)
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, records: records, pricing: pricing)
            let data = try JSONEncoder().encode(snapshot)
            let temporaryURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func pricingKey(provider: AIProvider, model: String) -> String { "\(provider.rawValue.lowercased())::\(model.lowercased())" }
}
