import Foundation

/// Shared deterministic task reference resolver used by runtime control and
/// diagnostics. It intentionally avoids an LLM so control actions can never
/// target a different task because of a probabilistic interpretation.
struct AgentTaskResolver {
    enum Resolution: Hashable {
        case found(AgentTask)
        case ambiguous([AgentTask])
        case notFound
    }

    func resolve(_ rawReference: String?, in tasks: [AgentTask]) -> Resolution {
        let ordered = tasks.sorted { $0.updatedAt > $1.updatedAt }
        guard !ordered.isEmpty else { return .notFound }

        guard let raw = rawReference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .found(ordered[0])
        }

        let reference = normalize(raw)

        if let exact = ordered.first(where: { $0.id.uuidString.lowercased() == reference }) {
            return .found(exact)
        }

        let prefixMatches = ordered.filter { $0.id.uuidString.lowercased().hasPrefix(reference) }
        if prefixMatches.count == 1 { return .found(prefixMatches[0]) }
        if prefixMatches.count > 1 { return .ambiguous(prefixMatches) }

        if let status = statusAlias(reference) {
            let matches = ordered.filter { $0.status == status }
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
        }

        let tokens = meaningfulTokens(reference)
        guard !tokens.isEmpty else { return .notFound }

        let scored = ordered.compactMap { task -> (AgentTask, Int)? in
            let searchable = normalize(task.title + " " + task.goal)
            let score = tokens.reduce(0) { $0 + (searchable.contains($1) ? 1 : 0) }
            return score > 0 ? (task, score) : nil
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.updatedAt > $1.0.updatedAt
        }

        guard let best = scored.first else { return .notFound }
        let tied = scored.filter { $0.1 == best.1 }.map(\.0)
        return tied.count == 1 ? .found(best.0) : .ambiguous(tied)
    }

    private func normalize(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "el_GR")
        ).lowercased()
    }

    private func statusAlias(_ reference: String) -> AgentTaskStatus? {
        if let direct = AgentTaskStatus(rawValue: reference) { return direct }
        let aliases: [String: AgentTaskStatus] = [
            "failed": .failed, "αποτυχημενο": .failed, "αποτυχια": .failed,
            "completed": .completed, "ολοκληρωμενο": .completed,
            "running": .running, "ενεργο": .running, "τρεχει": .running,
            "paused": .paused, "παγωμενο": .paused, "σε παυση": .paused,
            "cancelled": .cancelled, "ακυρωμενο": .cancelled,
            "waitingforapproval": .waitingForApproval, "approval": .waitingForApproval
        ]
        return aliases[reference]
    }

    private func meaningfulTokens(_ reference: String) -> [String] {
        let stopWords: Set<String> = [
            "task", "το", "του", "τη", "την", "για", "με", "μου", "ενα",
            "status", "log", "δειξε", "show", "previous", "προηγουμενο",
            "τελευταιο", "latest", "run", "auto", "resume", "retry", "cancel"
        ]
        return reference
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}
