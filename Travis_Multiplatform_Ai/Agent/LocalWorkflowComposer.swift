import Foundation

/// Builds autonomous plans from already-structured local invocations. This is
/// intentionally not a natural-language planner: every operation and argument
/// must already be explicit, so composing the plan itself costs zero AI tokens.
@MainActor
final class LocalWorkflowComposer {
    static let shared = LocalWorkflowComposer()

    struct StepSpec: Hashable {
        var title: String
        var invocation: DeterministicCapabilityInvocation
        var successCriteria: [String]
        var riskLevelOverride: PlanStepRiskLevel?

        init(
            title: String,
            invocation: DeterministicCapabilityInvocation,
            successCriteria: [String] = ["The capability returns a non-empty result that can be verified."],
            riskLevel: PlanStepRiskLevel? = nil
        ) {
            self.title = title
            self.invocation = invocation
            self.successCriteria = successCriteria
            self.riskLevelOverride = riskLevel
        }
    }

    enum CompositionError: LocalizedError {
        case emptyWorkflow
        case missingCapability(String)
        case capabilityNotDeterministic(String)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyWorkflow: return "Το local workflow δεν περιέχει steps."
            case .missingCapability(let id): return "Το capability \(id) δεν είναι registered."
            case .capabilityNotDeterministic(let id): return "Το capability \(id) δεν υποστηρίζει structured deterministic invocation."
            case .encodingFailed(let id): return "Απέτυχε η κωδικοποίηση structured invocation για \(id)."
            }
        }
    }

    func compose(
        summary: String,
        steps specs: [StepSpec],
        capabilities: [AgentCapability]
    ) throws -> TaskPlan {
        guard !specs.isEmpty else { throw CompositionError.emptyWorkflow }
        let capabilityMap = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

        var previous: UUID?
        var steps: [PlanStep] = []
        steps.reserveCapacity(specs.count)

        for (index, spec) in specs.enumerated() {
            guard let capability = capabilityMap[spec.invocation.capabilityId] else {
                throw CompositionError.missingCapability(spec.invocation.capabilityId)
            }
            guard capability is any DeterministicInvocableCapability else {
                throw CompositionError.capabilityNotDeterministic(spec.invocation.capabilityId)
            }

            let envelope: String
            do { envelope = try StructuredInvocationCodec.encode(spec.invocation) }
            catch { throw CompositionError.encodingFailed(spec.invocation.capabilityId) }

            let descriptor = capability.descriptor
            let provider = capability as? any DeterministicInvocationPolicyProviding
            let needsApproval = provider?.requiresApproval(for: spec.invocation)
                ?? (descriptor.policy.requiresExplicitApproval || descriptor.policy.declares(.localMutation))
            let riskLevel = spec.riskLevelOverride
                ?? provider?.riskLevel(for: spec.invocation)
                ?? .low

            let stepId = UUID()
            steps.append(PlanStep(
                id: stepId,
                order: index + 1,
                title: spec.title,
                instructions: envelope,
                status: .pending,
                capabilityId: spec.invocation.capabilityId,
                dependencyStepIds: previous.map { [$0] } ?? [],
                successCriteria: spec.successCriteria,
                riskLevel: riskLevel,
                requiresApproval: needsApproval,
                canRunInBackground: descriptor.policy.supportsBackgroundExecution,
                estimatedEffort: .short,
                maxAttempts: min(2, descriptor.policy.maxAttempts)
            ))
            previous = stepId
        }

        LocalIntelligenceMetrics.shared.record(.deterministicSkillPlan)
        return TaskPlan(
            version: 1,
            summary: summary.isEmpty ? "Structured local workflow — zero cloud planning tokens" : summary,
            steps: steps
        )
    }
}
