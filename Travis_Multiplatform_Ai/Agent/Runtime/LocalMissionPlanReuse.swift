import Foundation

struct LocalMissionPlanReuseDecision: Hashable {
    let sourceTaskId: UUID
    let confidence: Double
    let plan: TaskPlan
}

/// Reuses only the STRUCTURE of a previously completed mission.
/// Results are never copied. The new mission still executes every capability
/// again and must pass the normal verification path.
enum LocalMissionPlanReuse {
    static func makePlan(
        for goal: String,
        from tasks: [AgentTask],
        availableCapabilityIds: Set<String>,
        minimumConfidence: Double = 0.82
    ) -> LocalMissionPlanReuseDecision? {
        let queryTerms = terms(from: goal)
        guard queryTerms.count >= 3 else { return nil }

        let candidates = tasks
            .filter { $0.status == .completed && !$0.plan.steps.isEmpty }
            .compactMap { task -> (AgentTask, Double)? in
                let candidateTerms = terms(from: task.goal + " " + task.title)
                guard candidateTerms.count >= 3 else { return nil }

                let overlap = queryTerms.intersection(candidateTerms)
                guard overlap.count >= 3 else { return nil }

                let queryCoverage = Double(overlap.count) / Double(queryTerms.count)
                let candidateCoverage = Double(overlap.count) / Double(candidateTerms.count)
                let confidence = min(1, queryCoverage * 0.72 + candidateCoverage * 0.28)

                let capabilityIds = Set(task.plan.steps.compactMap(\.capabilityId))
                guard capabilityIds.isSubset(of: availableCapabilityIds) else { return nil }
                guard task.plan.steps.allSatisfy({ $0.status == .completed }) else { return nil }

                return confidence >= minimumConfidence ? (task, confidence) : nil
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.updatedAt > rhs.0.updatedAt
            }

        guard let (source, confidence) = candidates.first else { return nil }
        return LocalMissionPlanReuseDecision(
            sourceTaskId: source.id,
            confidence: confidence,
            plan: clonedPlan(from: source.plan)
        )
    }

    private static func clonedPlan(from source: TaskPlan) -> TaskPlan {
        let sorted = source.steps.sorted { $0.order < $1.order }
        var newIdByOldId: [UUID: UUID] = [:]
        for step in sorted { newIdByOldId[step.id] = UUID() }

        let steps = sorted.map { step in
            PlanStep(
                id: newIdByOldId[step.id]!,
                order: step.order,
                title: step.title,
                instructions: step.instructions,
                status: .pending,
                capabilityId: step.capabilityId,
                dependencyStepIds: step.dependencyStepIds.compactMap { newIdByOldId[$0] },
                successCriteria: step.successCriteria,
                riskLevel: step.riskLevel,
                requiresApproval: step.requiresApproval,
                canRunInBackground: step.canRunInBackground,
                estimatedEffort: step.estimatedEffort,
                attemptCount: 0,
                maxAttempts: step.maxAttempts,
                startedAt: nil,
                completedAt: nil,
                lastError: nil,
                resultSummary: nil
            )
        }

        return TaskPlan(
            version: 1,
            summary: "Local learned plan reuse: \(source.summary)",
            steps: steps
        )
    }

    private static func terms(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "this", "that", "with", "from", "into", "then", "than", "when", "where", "what", "have", "will", "should", "could", "would", "your", "their", "there", "about", "after", "before", "using", "make", "create", "check", "please",
            "και", "που", "την", "τον", "των", "στο", "στη", "στην", "απο", "για", "με", "να", "το", "τα", "της", "του", "ενα", "μια", "πως", "οταν"
        ]

        return Set(
            text.lowercased()
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }
}
