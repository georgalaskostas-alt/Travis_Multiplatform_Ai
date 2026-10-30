import Foundation

/// Central policy decision point for autonomous execution. Planner risk and
/// requiresApproval are inputs, never authority. Read-only analysis should stay
/// autonomous; external mutation and self-modification are approval-gated.
struct AgentPolicyEngine {
    enum Decision: Hashable {
        case allow
        case requireApproval(reason: String)
        case deny(reason: String)
    }

    func evaluate(step: PlanStep, capabilityId: String) -> Decision {
        if step.riskLevel == .critical {
            return .requireApproval(reason: "Critical-risk autonomous action requires explicit approval.")
        }

        if step.requiresApproval || step.riskLevel == .high {
            return .requireApproval(reason: "Planner/policy risk requires explicit approval.")
        }

        let id = capabilityId.lowercased()
        let actionText = normalize(step.title + " " + step.instructions)

        if id.contains("trading"), containsMutationIntent(actionText, domain: .trading) {
            return .requireApproval(reason: "Trading execution requires explicit approval; analysis remains autonomous.")
        }

        if id.contains("self_improvement"), containsMutationIntent(actionText, domain: .code) {
            return .requireApproval(reason: "Self-modifying code action requires explicit approval; inspection remains autonomous.")
        }

        return .allow
    }

    private enum MutationDomain { case trading, code }

    private func containsMutationIntent(_ text: String, domain: MutationDomain) -> Bool {
        let tokens: [String]
        switch domain {
        case .trading:
            tokens = [
                "place order", "submit order", "open position", "close position",
                "execute trade", "buy ", "sell ", "testnet order", "trade execution",
                "ανοιξε θεση", "κλεισε θεση", "εκτελεσε εντολη", "αγορασε", "πουλησε"
            ]
        case .code:
            tokens = [
                "modify code", "edit code", "write patch", "apply patch", "commit change",
                "delete file", "replace file", "self modify", "αλλαξε κωδικα", "τροποποιησε κωδικα",
                "γραψε patch", "εφαρμοσε patch", "κανε commit", "διαγραψε αρχειο"
            ]
        }
        return tokens.contains { text.contains($0) }
    }

    private func normalize(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "el_GR")
        ).lowercased()
    }
}
