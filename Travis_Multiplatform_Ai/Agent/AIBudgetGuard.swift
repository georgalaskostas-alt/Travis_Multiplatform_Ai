import Foundation

@MainActor
struct AIBudgetGuard {
    enum BudgetError: LocalizedError, Equatable {
        case tokenBudgetExceeded(taskId: UUID, used: Int, projected: Int, limit: Int)
        case costBudgetExceeded(taskId: UUID, used: Double, projected: Double, limit: Double)
        case costBudgetUnverifiable(taskId: UUID)
        case globalTokenBudgetExceeded(period: String, used: Int, projected: Int, limit: Int)
        case globalCostBudgetExceeded(period: String, used: Double, projected: Double, limit: Double)
        case globalCostBudgetUnverifiable(period: String)

        var errorDescription: String? {
            switch self {
            case .tokenBudgetExceeded(let taskId, let used, let projected, let limit):
                return "AI token budget exceeded for task \(taskId.uuidString.prefix(8)): used \(used), projected next request \(projected), limit \(limit)."
            case .costBudgetExceeded(let taskId, let used, let projected, let limit):
                return String(format: "AI cost budget exceeded for task %@: used $%.4f, projected next request $%.4f, limit $%.4f.", String(taskId.uuidString.prefix(8)), used, projected, limit)
            case .costBudgetUnverifiable(let taskId):
                return "AI cost budget cannot be safely verified for task \(taskId.uuidString.prefix(8)) because prior usage includes models without configured pricing."
            case .globalTokenBudgetExceeded(let period, let used, let projected, let limit):
                return "Global AI token budget exceeded for \(period): used \(used), projected next request \(projected), limit \(limit)."
            case .globalCostBudgetExceeded(let period, let used, let projected, let limit):
                return String(format: "Global AI cost budget exceeded for %@: used $%.4f, projected next request $%.4f, limit $%.4f.", period, used, projected, limit)
            case .globalCostBudgetUnverifiable(let period):
                return "Global AI cost budget cannot be safely verified for \(period) because usage includes models without configured pricing."
            }
        }
    }

    private enum GlobalKey {
        static let dailyTokens = "ai.budget.dailyTokens"
        static let monthlyTokens = "ai.budget.monthlyTokens"
        static let dailyCostUSD = "ai.budget.dailyCostUSD"
        static let monthlyCostUSD = "ai.budget.monthlyCostUSD"
    }

    private let taskStore: AgentTaskStore
    private let ledger: AIUsageLedger
    private let defaults: UserDefaults

    init(
        taskStore: AgentTaskStore = .shared,
        ledger: AIUsageLedger = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.taskStore = taskStore
        self.ledger = ledger
        self.defaults = defaults
    }

    func preflight(
        prompt: String,
        maxOutputTokens: Int,
        selection: AIModelSelection,
        context: AIInvocationContext
    ) throws {
        let estimatedInputTokens = Self.conservativeInputEstimate(prompt)
        let projectedTokens = estimatedInputTokens + max(0, maxOutputTokens)

        try enforceGlobalBudgets(
            projectedTokens: projectedTokens,
            estimatedInputTokens: estimatedInputTokens,
            maxOutputTokens: maxOutputTokens,
            selection: selection
        )

        guard let taskId = context.taskId,
              let task = try? taskStore.load().first(where: { $0.id == taskId }) else {
            return
        }

        let currentUsage = ledger.taskUsage(taskId: taskId)

        if let limit = task.budget.maxAITokens,
           currentUsage.totalTokens + projectedTokens > limit {
            throw BudgetError.tokenBudgetExceeded(
                taskId: taskId,
                used: currentUsage.totalTokens,
                projected: projectedTokens,
                limit: limit
            )
        }

        guard let costLimit = task.budget.maxAICostUSD else { return }

        if ledger.hasUnknownCostUsage(taskId: taskId) {
            throw BudgetError.costBudgetUnverifiable(taskId: taskId)
        }

        guard let pricing = ledger.pricingFor(provider: selection.provider, model: selection.model) else {
            throw BudgetError.costBudgetUnverifiable(taskId: taskId)
        }

        let projectedUsage = AITokenUsage(
            inputTokens: estimatedInputTokens,
            outputTokens: max(0, maxOutputTokens)
        )
        let projectedCost = pricing.estimatedCost(for: projectedUsage)
        let usedCost = ledger.estimatedSpendUSD(taskId: taskId)

        if usedCost + projectedCost > costLimit {
            throw BudgetError.costBudgetExceeded(
                taskId: taskId,
                used: usedCost,
                projected: projectedCost,
                limit: costLimit
            )
        }
    }

    private func enforceGlobalBudgets(
        projectedTokens: Int,
        estimatedInputTokens: Int,
        maxOutputTokens: Int,
        selection: AIModelSelection,
        now: Date = Date()
    ) throws {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfDay

        let periods: [(name: String, start: Date, tokenLimit: Int, costLimit: Double)] = [
            ("today", startOfDay, defaults.integer(forKey: GlobalKey.dailyTokens), defaults.double(forKey: GlobalKey.dailyCostUSD)),
            ("this month", startOfMonth, defaults.integer(forKey: GlobalKey.monthlyTokens), defaults.double(forKey: GlobalKey.monthlyCostUSD))
        ]

        for period in periods {
            if period.tokenLimit > 0 {
                let used = ledger.usageSummary(since: period.start).totalTokens
                if used + projectedTokens > period.tokenLimit {
                    throw BudgetError.globalTokenBudgetExceeded(
                        period: period.name,
                        used: used,
                        projected: projectedTokens,
                        limit: period.tokenLimit
                    )
                }
            }

            guard period.costLimit > 0 else { continue }

            let records = ledger.records.filter { $0.timestamp >= period.start && $0.succeeded && $0.usage.totalTokens > 0 }
            if records.contains(where: { $0.estimatedCostUSD == nil }) {
                throw BudgetError.globalCostBudgetUnverifiable(period: period.name)
            }
            guard let pricing = ledger.pricingFor(provider: selection.provider, model: selection.model) else {
                throw BudgetError.globalCostBudgetUnverifiable(period: period.name)
            }

            let projectedUsage = AITokenUsage(
                inputTokens: estimatedInputTokens,
                outputTokens: max(0, maxOutputTokens)
            )
            let projectedCost = pricing.estimatedCost(for: projectedUsage)
            let usedCost = ledger.estimatedSpendUSD(since: period.start)
            if usedCost + projectedCost > period.costLimit {
                throw BudgetError.globalCostBudgetExceeded(
                    period: period.name,
                    used: usedCost,
                    projected: projectedCost,
                    limit: period.costLimit
                )
            }
        }
    }

    /// Deliberately conservative tokenizer-free estimate. Exact provider
    /// tokenization is model-specific; a hard budget guard should overestimate
    /// rather than allow a request that can breach the configured ceiling.
    private static func conservativeInputEstimate(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 3.0)))
    }
}
