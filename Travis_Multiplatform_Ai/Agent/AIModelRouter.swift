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
        availability: AIProviderAvailability
    ) -> [AIModelSelection] {
        let workload = resolvedWorkload(prompt: prompt, context: context)
        guard workload != .deterministic else { return [] }

        var result: [AIModelSelection] = []

        // Cheap local inference gets first chance only for low-risk cognitive
        // workloads. Complex verification/frontier work is never silently
        // downgraded to a local model merely because it is cheaper.
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

        // OpenRouter is optional and model IDs are user/config supplied. We do
        // not invent a provider/model mapping in code because availability and
        // pricing change independently of the app release cycle.
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

        // De-duplicate identical provider/model pairs while preserving the
        // intended escalation order.
        var seen = Set<String>()
        return result.filter { selection in
            seen.insert("\(selection.provider.rawValue)::\(selection.model)").inserted
        }
    }

    private func resolvedWorkload(prompt: String, context: AIInvocationContext) -> AIWorkloadClass {
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
}
