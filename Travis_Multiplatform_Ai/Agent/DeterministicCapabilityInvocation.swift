import Foundation

/// A structured invocation produced by trusted/local parsing or a mature skill.
/// It is deliberately data-only: policy/approval remains owned by the capability
/// and UniversalCapabilityRunner.
struct DeterministicCapabilityInvocation: Codable, Hashable, Sendable {
    var capabilityId: String
    var operation: String
    var arguments: [String: String]

    init(capabilityId: String, operation: String, arguments: [String: String] = [:]) {
        self.capabilityId = capabilityId
        self.operation = operation
        self.arguments = arguments
    }
}

/// Opt-in contract. Capabilities that can safely execute structured operations
/// implement this without forcing every existing capability to migrate.
protocol DeterministicInvocableCapability: AgentCapability {
    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome
}

/// Optional finer-grained policy metadata for structured operations. This
/// prevents a mixed read/write capability from forcing approval on harmless
/// reads just because some other operation in the same capability mutates state.
protocol DeterministicInvocationPolicyProviding {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel
}

extension DeterministicInvocationPolicyProviding where Self: AgentCapability {
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool {
        descriptor.policy.requiresExplicitApproval || descriptor.policy.declares(.localMutation)
    }

    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel {
        descriptor.policy.declares(.financial) || descriptor.policy.declares(.externalMutation) ? .high : .low
    }
}
