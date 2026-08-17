import Foundation

struct AIProviderAvailability {
    var hasOpenAI: Bool
    var hasAnthropic: Bool
    var hasOpenRouter: Bool
    var localBaseURL: URL?
    var localModel: String?
    var preferences: AIProviderPreferences

    var hasLocal: Bool { localBaseURL != nil && localModel != nil }
}

/// Central cost-aware routing policy. It returns an ordered escalation chain,
/// not a single provider. Capabilities never know which provider/model serves
/// their request.
struct AIModelRouter {
    func candidates(
        for prompt: String,
        context: AIInvocationContext,
        availability: AIProviderAvailability,
        performanceScores: [AIModelPerformanceService.Score] = []
    ) -> [AIModelSelection] {
        let workload = workload(for: prompt, context: context)
        guard workload != .deterministic else { return [] }

        var result: [AIModelSelection] = []

        if availability.hasLocal,
           [.classification, .routine].contains(workload),
           let model = availability.localModel {
            result.append(AIModelSelection(
                provider: .local,
                model: model,
                tier: .local,
                reasoningEffort: nil,
                rationale: "Local-first low-cost inference"
            ))
        }

        if availability.hasOpenRouter,
           let model = availability.preferences.openRouterModel(for: workload) {
            let tier: AIModelTier
            switch workload {
            case .classification: tier = .economy
            case .routine: tier = .standard
            case .complex, .verification: tier = .strong
            case .frontier, .webResearch: tier = .frontier
            case .deterministic: tier = .local
            }
            result.append(AIModelSelection(
                provider: .openRouter,
                model: model,
                tier: tier,
                reasoningEffort: workload == .classification || workload == .routine ? "low" : "medium",
                rationale: "Configured OpenRouter model for cost-aware routing"
            ))
        }

        if availability.hasOpenAI {
            switch workload {
            case .classification:
                result.append(AIModelSelection(provider: .openAI, model: "gpt-5.6-luna", tier: .economy, reasoningEffort: "low", rationale: "Direct OpenAI economy classification fallback"))
            case .routine:
                result.append(AIModelSelection(provider: .openAI, model: "gpt-5.6-luna", tier: .standard, reasoningEffort: "low", rationale: "Direct OpenAI routine fallback"))
            case .complex, .verification:
                result.append(AIModelSelection(provider: .openAI, model: "gpt-5.6-terra", tier: .strong, reasoningEffort: "medium", rationale: "Direct OpenAI strong reasoning"))
            case .frontier, .webResearch:
                result.append(AIModelSelection(provider: .openAI, model: "gpt-5.6-terra", tier: .frontier, reasoningEffort: "medium", rationale: "Direct OpenAI frontier reasoning"))
            case .deterministic:
                break
            }
        }

        if availability.hasAnthropic {
            result.append(AIModelSelection(
                provider: .anthropic,
                model: "claude-sonnet-4-6",
                tier: workload == .classification ? .standard : .strong,
                reasoningEffort: nil,
                rationale: "Cross-provider Anthropic fallback"
            ))
        }

        var seen = Set<String>()
        let deduplicated = result.filter { selection in
            seen.insert("\(selection.provider.rawValue)::\(selection.model)").inserted
        }

        return adaptiveOrder(
            deduplicated,
            workload: workload,
            scores: performanceScores
        )
    }

    func workload(for prompt: String, context: AIInvocationContext) -> AIWorkloadClass {
        if context.workload != .routine { return context.workload }

        let value = prompt.lowercased()
        let classificationMarkers = [
            "intent classifier", "route one user message", "return json only",
            "capabilityid", "allowed intents"
        ]
        if classificationMarkers.contains(where: value.contains) { return .classification }

        let complexMarkers = [
            "planning component", "repository-analysis component", "repository tree",
            "selected source files", "source code", "architecture",
            "autonomous runtime", "taskplanner", "verify the execution"
        ]
        if complexMarkers.contains(where: value.contains) { return .complex }

        return .routine
    }

    /// Historical performance may optimize ordering only within a safe tier
    /// envelope. It can never demote verification/frontier work to local or
    /// economy models, and it needs enough samples before affecting routing.
    private func adaptiveOrder(
        _ candidates: [AIModelSelection],
        workload: AIWorkloadClass,
        scores: [AIModelPerformanceService.Score]
    ) -> [AIModelSelection] {
        guard candidates.count > 1 else { return candidates }

        let minimumSamples = 5
        let scoreMap = Dictionary(uniqueKeysWithValues: scores
            .filter { $0.workload == workload && $0.requestCount >= minimumSamples }
            .map { ("\($0.provider.rawValue)::\($0.model)", $0) })

        guard !scoreMap.isEmpty else { return candidates }

        let originalIndex = Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            ("\($0.element.provider.rawValue)::\($0.element.model)", $0.offset)
        })

        return candidates.sorted { lhs, rhs in
            let lhsRank = safeTierRank(lhs.tier, workload: workload)
            let rhsRank = safeTierRank(rhs.tier, workload: workload)

            // Never reorder across safety envelopes. Lower rank means cheaper
            // tier and is attempted first only where that workload permits it.
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            let lhsKey = "\(lhs.provider.rawValue)::\(lhs.model)"
            let rhsKey = "\(rhs.provider.rawValue)::\(rhs.model)"
            let lhsScore = scoreMap[lhsKey]
            let rhsScore = scoreMap[rhsKey]

            switch (lhsScore, rhsScore) {
            case let (left?, right?):
                if abs(left.utilityScore - right.utilityScore) > 0.01 {
                    return left.utilityScore > right.utilityScore
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return (originalIndex[lhsKey] ?? 0) < (originalIndex[rhsKey] ?? 0)
        }
    }

    private func safeTierRank(_ tier: AIModelTier, workload: AIWorkloadClass) -> Int {
        switch workload {
        case .classification:
            switch tier { case .local: return 0; case .economy: return 1; case .standard: return 2; case .strong: return 3; case .frontier: return 4 }
        case .routine:
            switch tier { case .local: return 0; case .economy: return 1; case .standard: return 1; case .strong: return 2; case .frontier: return 3 }
        case .complex:
            switch tier { case .strong: return 0; case .frontier: return 1; case .standard: return 2; case .economy: return 3; case .local: return 4 }
        case .verification, .frontier, .webResearch:
            switch tier { case .frontier: return 0; case .strong: return 0; case .standard: return 2; case .economy: return 3; case .local: return 4 }
        case .deterministic:
            return 0
        }
    }
}
