import Foundation

@MainActor
struct AIBudgetGuard {
    enum BudgetError: LocalizedError, Equatable {
        case tokenBudgetExceeded(taskId: UUID, used: Int, projected: Int, limit: Int)
        case costBudgetExceeded(taskId: UUID, used: Double, projected: Double, limit: Double)
        case costBudgetUnverifiable(taskId: UUID)

        var errorDescription: String? {
            switch self {
            case .tokenBudgetExceeded(let taskId, let used, let projected, let limit):
                return "AI token budget exceeded for task \(taskId.uuidString.prefix(8)): used \(used), projected next request \(projected), limit \(limit)."
            case .costBudgetExceeded(let taskId, let used, let projected, let limit):
                return String(format: "AI cost budget exceeded for task %@: used $%.4f, projected next request $%.4f, limit $%.4f.", String(taskId.uuidString.prefix(8)), used, projected, limit)
            case .costBudgetUnverifiable(let taskId):
                return "AI cost budget cannot be safely verified for task \(taskId.uuidString.prefix(8)) because prior usage includes models without configured pricing."
            }
        }
    }

    private let taskStore: AgentTaskStore
    private let ledger: AIUsageLedger

    init(taskStore: AgentTaskStore = .shared, ledger: AIUsageLedger = .shared) {
        self.taskStore = taskStore
        self.ledger = ledger
    }

    func preflight(
        prompt: String,
        maxOutputTokens: Int,
        selection: AIModelSelection,
        context: AIInvocationContext
    ) throws {
        guard let taskId = context.taskId,
              let task = try? taskStore.load().first(where: { $0.id == taskId }) else {
            return
        }

        let currentUsage = ledger.taskUsage(taskId: taskId)
        let estimatedInputTokens = Self.conservativeInputEstimate(prompt)
        let projectedTokens = estimatedInputTokens + max(0, maxOutputTokens)

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

        // If prior successful usage has unknown pricing, we cannot honestly
        // prove that the remaining dollar budget is safe. Fail closed rather
        // than pretending unknown-cost tokens were free.
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

    /// Deliberately conservative tokenizer-free estimate. Exact provider
    /// tokenization is model-specific; a hard budget guard should overestimate
    /// rather than allow a request that can breach the configured ceiling.
    private static func conservativeInputEstimate(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 3.0)))
    }
}
