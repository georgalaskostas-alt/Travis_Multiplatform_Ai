import Foundation

enum AIWorkloadClass: String, Codable, CaseIterable, Hashable {
    case deterministic
    case classification
    case routine
    case complex
    case frontier
    case webResearch
    case verification
}

enum AIModelTier: String, Codable, CaseIterable, Hashable {
    case local
    case economy
    case standard
    case strong
    case frontier
}

struct AIInvocationContext: Codable, Hashable {
    var workload: AIWorkloadClass
    var capabilityId: String?
    var taskId: UUID?
    var stepId: UUID?
    var projectId: UUID?
    var operation: String?

    init(
        workload: AIWorkloadClass = .routine,
        capabilityId: String? = nil,
        taskId: UUID? = nil,
        stepId: UUID? = nil,
        projectId: UUID? = nil,
        operation: String? = nil
    ) {
        self.workload = workload
        self.capabilityId = capabilityId
        self.taskId = taskId
        self.stepId = stepId
        self.projectId = projectId
        self.operation = operation
    }

    /// Source-compatible default used by all existing AIService call sites.
    /// Inside UniversalCapabilityRunner it resolves to the current task-local
    /// provenance; outside autonomous execution it resolves to neutral context.
    static var general: AIInvocationContext { AIExecutionScope.context }
}

struct AIModelSelection: Codable, Hashable {
    var provider: AIProvider
    var model: String
    var tier: AIModelTier
    var reasoningEffort: String?
    var rationale: String
}

struct AITokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningTokens: Int

    init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }

    var totalTokens: Int { inputTokens + outputTokens }
}

struct AIModelPricing: Codable, Hashable {
    var inputUSDPerMillion: Double
    var outputUSDPerMillion: Double
    var cachedInputUSDPerMillion: Double?

    func estimatedCost(for usage: AITokenUsage) -> Double {
        let uncachedInput = max(0, usage.inputTokens - usage.cachedInputTokens)
        let input = Double(uncachedInput) / 1_000_000 * inputUSDPerMillion
        let cachedRate = cachedInputUSDPerMillion ?? inputUSDPerMillion
        let cached = Double(usage.cachedInputTokens) / 1_000_000 * cachedRate
        let output = Double(usage.outputTokens) / 1_000_000 * outputUSDPerMillion
        return input + cached + output
    }
}

struct AIUsageRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var timestamp: Date
    var provider: AIProvider
    var model: String
    var tier: AIModelTier
    var workload: AIWorkloadClass
    var capabilityId: String?
    var taskId: UUID?
    var stepId: UUID?
    var projectId: UUID?
    var operation: String?
    var usage: AITokenUsage
    var estimatedCostUSD: Double?
    var latencyMilliseconds: Int
    var attempt: Int
    var succeeded: Bool
    var errorType: String?

    init(
        id: UUID = UUID(), timestamp: Date = Date(), provider: AIProvider,
        model: String, tier: AIModelTier, context: AIInvocationContext,
        usage: AITokenUsage, estimatedCostUSD: Double?, latencyMilliseconds: Int,
        attempt: Int, succeeded: Bool, errorType: String? = nil
    ) {
        self.id = id; self.timestamp = timestamp; self.provider = provider; self.model = model; self.tier = tier
        self.workload = context.workload; self.capabilityId = context.capabilityId; self.taskId = context.taskId
        self.stepId = context.stepId; self.projectId = context.projectId; self.operation = context.operation
        self.usage = usage; self.estimatedCostUSD = estimatedCostUSD; self.latencyMilliseconds = latencyMilliseconds
        self.attempt = attempt; self.succeeded = succeeded; self.errorType = errorType
    }
}
