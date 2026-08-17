import Foundation

/// Converts mature, verified deterministic skills into a fresh runtime plan
/// without invoking a cloud planner. This is a planning optimization only:
/// runtime policy, approval gates, capability execution and verification still
/// apply to every generated step.
@MainActor
final class SkillExecutionEngine {
    static let shared = SkillExecutionEngine()

    struct Match {
        let skill: ReusableSkillStore.Skill
        let similarity: Double
        let distilled: SkillDistillationService.DistilledSkill
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

    func deterministicPlan(
        for goal: String,
        capabilities: [AgentCapability]
    ) -> Match? {
        let available = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0.descriptor) })
        let candidates = skills.matchingSkills(for: goal, limit: 5)

        for candidate in candidates {
            guard candidate.skill.observationCount >= 2,
                  candidate.similarity >= 0.88,
                  let distilled = distillation.item(for: candidate.skill.id),
                  distilled.executionClass == .deterministicCandidate,
                  distilled.confidence >= 0.85,
                  candidate.skill.steps.allSatisfy({ available[$0.capabilityId] != nil }) else {
                continue
            }

            let plan = materialize(skill: candidate.skill, descriptors: available)
            return Match(
                skill: candidate.skill,
                similarity: candidate.similarity,
                distilled: distilled,
                plan: plan
            )
        }

        return nil
    }

    private func materialize(
        skill: ReusableSkillStore.Skill,
        descriptors: [String: CapabilityDescriptor]
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

        return TaskPlan(
            version: 1,
            summary: "Reused mature verified skill locally without cloud planning: \(skill.title)",
            steps: freshSteps
        )
    }
}
