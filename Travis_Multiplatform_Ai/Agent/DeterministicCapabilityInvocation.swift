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
