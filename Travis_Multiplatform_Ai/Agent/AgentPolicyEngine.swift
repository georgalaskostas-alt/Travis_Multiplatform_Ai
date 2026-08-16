import Foundation

/// Central policy decision point for autonomous execution. Planner risk and
/// requiresApproval are inputs, never authority. Capabilities can be tightened
/// here without duplicating safety rules throughout executors and UI.
struct AgentPolicyEngine {
    enum Decision: Hashable {
        case allow
        case requireApproval(reason: String)
        case deny(reason: String)
    }

    func evaluate(step: PlanStep, capabilityId: String) -> Decision {
        let id = capabilityId.lowercased()

        // Critical operations never run autonomously in Runtime v1.
        if step.riskLevel == .critical {
            return .requireApproval(reason: "Critical-risk autonomous action requires explicit approval.")
        }

        // Trading execution, self-modification and other externally mutating
        // capabilities are approval-gated regardless of planner output.
        let sensitiveCapability = id.contains("trading") || id.contains("self_improvement")
        if sensitiveCapability {
            return .requireApproval(reason: "Sensitive capability requires explicit approval.")
        }

        if step.requiresApproval || step.riskLevel == .high {
            return .requireApproval(reason: "Planner/policy risk requires explicit approval.")
        }

        return .allow
    }
}
