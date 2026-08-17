import Foundation

/// Reuses mature verified workflow structure before invoking a cloud planner.
/// Deterministic candidates are fully local planning reuse. Local-AI candidates
/// also reuse the plan skeleton locally, while their semantic capability calls
/// may still use the configured local model and escalate through AIService when
/// necessary. Runtime policy, approval and verification always remain active.
@MainActor
final class SkillExecutionEngine {
    static let shared = SkillExecutionEngine()

    enum PlanningMode: String, Hashable {
        case deterministic
        case localAI
    }

    struct Match {
        let skill: ReusableSkillStore.Skill
        let similarity: Double
        let distilled: SkillDistillationService.DistilledSkill
        let planningMode: PlanningMode
        let plan: TaskPlan
    }

    private let skills: ReusableSkillStore
    private let distillation: SkillDistillationService

    init(
        skills: ReusableSkillStore = .shared,
        distillation: SkillDistillationService = .shared
    ) {
        self.skills = skills
        self.distillation = distillation
    }

    func optimizedPlan(
        for goal: String,
        capabilities: [AgentCapability]
    ) -> Match? {
        let available = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0.descriptor) })
        let candidates = skills.matchingSkills(for: goal, limit: 5)

        for candidate in candidates {
            guard candidate.skill.observationCount >= 2,
                  candidate.similarity >= 0.88,
                  let distilled = distillation.item(for: candidate.skill.id),
                  distilled.confidence >= 0.82,
                  candidate.skill.steps.allSatisfy({ available[$0.capabilityId] != nil }) else {
                continue
            }

            let mode: PlanningMode
            switch distilled.executionClass {
            case .deterministicCandidate:
                mode = .deterministic
            case .localAICandidate:
                mode = .localAI
            case .cloudReasoningRequired:
                continue
            }

            let plan = materialize(skill: candidate.skill, descriptors: available, mode: mode)
            if mode == .deterministic {
                LocalIntelligenceMetrics.shared.record(.deterministicSkillPlan)
            } else {
                LocalIntelligenceMetrics.shared.record(.learnedCapabilityRoute)
            }

            return Match(
                skill: candidate.skill,
                similarity: candidate.similarity,
                distilled: distilled,
                planningMode: mode,
                plan: plan
            )
        }

        return nil
    }

    /// Kept for source compatibility with the current task-creation path.
    /// It now returns either a deterministic or local-AI eligible verified skill
    /// plan; both avoid a fresh cloud-planner call.
    func deterministicPlan(
        for goal: String,
        capabilities: [AgentCapability]
    ) -> Match? {
        optimizedPlan(for: goal, capabilities: capabilities)
    }

    private func materialize(
        skill: ReusableSkillStore.Skill,
        descriptors: [String: CapabilityDescriptor],
        mode: PlanningMode
    ) -> TaskPlan {
        var previousStepId: UUID?
        var freshSteps: [PlanStep] = []
        freshSteps.reserveCapacity(skill.steps.count)

        for historical in skill.steps.sorted(by: { $0.order < $1.order }) {
            let stepId = UUID()
            let descriptor = descriptors[historical.capabilityId]
            let localMutation = descriptor?.policy.declares(.localMutation) == true
            let descriptorApproval = descriptor?.policy.requiresExplicitApproval == true

            let step = PlanStep(
                id: stepId,
                order: freshSteps.count + 1,
                title: historical.title,
                instructions: historical.instructions,
                status: .pending,
                capabilityId: historical.capabilityId,
                dependencyStepIds: previousStepId.map { [$0] } ?? [],
                successCriteria: historical.successCriteria.isEmpty
                    ? ["The capability returns a non-empty result that can be verified."]
                    : historical.successCriteria,
                riskLevel: historical.riskLevel,
                requiresApproval: localMutation || descriptorApproval,
                canRunInBackground: descriptor?.policy.supportsBackgroundExecution ?? false,
                estimatedEffort: .short,
                maxAttempts: min(2, descriptor?.policy.maxAttempts ?? 2)
            )
            freshSteps.append(step)
            previousStepId = stepId
        }

        let source = mode == .deterministic ? "deterministic" : "local-AI eligible"
        return TaskPlan(
            version: 1,
            summary: "Reused mature verified \(source) skill without cloud planning: \(skill.title)",
            steps: freshSteps
        )
    }
}
