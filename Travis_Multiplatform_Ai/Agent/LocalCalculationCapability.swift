import Foundation

/// Small deterministic calculator for autonomous work that should never spend AI tokens.
/// Accepts only structured numeric operations; it does not evaluate arbitrary code/expressions.
@MainActor
final class LocalCalculationCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_calculation"
    let name = "Local Calculation"
    let capabilityDescription = "Zero-token deterministic arithmetic, percentages and descriptive statistics."
    let keywords = ["calculate", "calculator", "sum", "average", "percentage", "υπολογισε", "άθροισμα", "μεσος ορος", "ποσοστο"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .productivity,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: [],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 10,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        .reply("Το local_calculation χρησιμοποιεί structured numeric arguments για ασφαλείς deterministic υπολογισμούς.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong calculation invocation.") }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        let values = parseValues(invocation.arguments["values"])
        let result: Double
        switch invocation.operation {
        case "add":
            guard !values.isEmpty else { return .reply("Missing numeric values.") }
            result = values.reduce(0, +)
        case "subtract":
            guard values.count == 2 else { return .reply("Subtract requires exactly 2 values.") }
            result = values[0] - values[1]
        case "multiply":
            guard !values.isEmpty else { return .reply("Missing numeric values.") }
            result = values.reduce(1, *)
        case "divide":
            guard values.count == 2, values[1] != 0 else { return .reply("Divide requires 2 values and a non-zero divisor.") }
            result = values[0] / values[1]
        case "average":
            guard !values.isEmpty else { return .reply("Missing numeric values.") }
            result = values.reduce(0, +) / Double(values.count)
        case "min":
            guard let value = values.min() else { return .reply("Missing numeric values.") }
            result = value
        case "max":
            guard let value = values.max() else { return .reply("Missing numeric values.") }
            result = value
        case "percent_of":
            guard values.count == 2 else { return .reply("percent_of requires percentage and base value.") }
            result = values[0] * values[1] / 100
        case "percent_change":
            guard values.count == 2, values[0] != 0 else { return .reply("percent_change requires non-zero old value and new value.") }
            result = (values[1] - values[0]) / values[0] * 100
        default:
            return .reply("Unsupported local calculation: \(invocation.operation)")
        }
        guard result.isFinite else { return .reply("Calculation produced a non-finite result.") }
        return .reply("LOCAL CALCULATION\n\n\(render(result))\n\n0 AI tokens")
    }

    func resolve(_ action: ProposedAction) {}

    private func parseValues(_ raw: String?) -> [Double] {
        guard let raw else { return [] }
        return raw.split(separator: "|").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) }
    }

    private func render(_ value: Double) -> String {
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.10g", value)
    }
}
