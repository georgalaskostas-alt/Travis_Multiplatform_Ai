import Foundation

/// Central policy for choosing provider/model tier. It deliberately separates
/// workload classification from transport so future OpenRouter/local models can
/// be added without changing planners, capabilities or the autonomous runtime.
struct AIModelRouter {
    func selection(
        for prompt: String,
        context: AIInvocationContext,
        hasOpenAI: Bool,
        hasAnthropic: Bool
    ) -> AIModelSelection? {
        guard hasOpenAI || hasAnthropic else { return nil }

        let workload = resolvedWorkload(prompt: prompt, context: context)

        if hasOpenAI {
            switch workload {
            case .classification:
                return AIModelSelection(
                    provider: .openAI,
                    model: "gpt-5.6-luna",
                    tier: .economy,
                    reasoningEffort: "low",
                    rationale: "Low-cost routing/classification workload"
                )
            case .routine:
                return AIModelSelection(
                    provider: .openAI,
                    model: "gpt-5.6-luna",
                    tier: .standard,
                    reasoningEffort: "low",
                    rationale: "Routine assistant workload"
                )
            case .complex, .verification:
                return AIModelSelection(
                    provider: .openAI,
                    model: "gpt-5.6-terra",
                    tier: .strong,
                    reasoningEffort: "medium",
                    rationale: "Complex planning/repository/verification workload"
                )
            case .frontier, .webResearch:
                return AIModelSelection(
                    provider: .openAI,
                    model: "gpt-5.6-terra",
                    tier: .frontier,
                    reasoningEffort: "medium",
                    rationale: "Frontier or web-grounded workload"
                )
            case .deterministic:
                return nil
            }
        }

        if hasAnthropic {
            return AIModelSelection(
                provider: .anthropic,
                model: "claude-sonnet-4-6",
                tier: workload == .classification ? .standard : .strong,
                reasoningEffort: nil,
                rationale: "Anthropic fallback because OpenAI is unavailable"
            )
        }

        return nil
    }

    func fallbackSelection(after primary: AIModelSelection, hasAnthropic: Bool) -> AIModelSelection? {
        guard hasAnthropic, primary.provider != .anthropic else { return nil }
        return AIModelSelection(
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            tier: .strong,
            reasoningEffort: nil,
            rationale: "Cross-provider fallback after primary failure"
        )
    }

    private func resolvedWorkload(prompt: String, context: AIInvocationContext) -> AIWorkloadClass {
        if context.workload != .routine { return context.workload }

        let value = prompt.lowercased()
        let classificationMarkers = [
            "intent classifier",
            "route one user message",
            "return json only",
            "capabilityid",
            "allowed intents"
        ]
        if classificationMarkers.contains(where: value.contains) { return .classification }

        let complexMarkers = [
            "planning component",
            "repository-analysis component",
            "repository tree",
            "selected source files",
            "source code",
            "architecture",
            "autonomous runtime",
            "taskplanner",
            "verify the execution"
        ]
        if complexMarkers.contains(where: value.contains) { return .complex }

        return .routine
    }
}
