import Foundation

/// Extracts durable project-memory actions from natural language. This layer
/// never mutates storage itself; TRAVISAppState resolves the target project
/// deterministically before applying any change.
@MainActor
final class ProjectMemoryIntentRouter {
    enum Intent: Hashable {
        case none
        case addDecision(reference: String?, text: String, rationale: String?)
        case addNote(reference: String?, text: String)
        case addGoal(reference: String?, text: String)
        case addPending(reference: String?, text: String)
        case completePending(reference: String?, query: String)
        case addDeliverable(reference: String?, name: String, path: String?)
        case markDeliverableReady(reference: String?, query: String, path: String?)
        case showProject(reference: String?)
        case continueLatest
    }

    private struct Decision: Decodable {
        let intent: String
        let reference: String?
        let text: String?
        let rationale: String?
        let path: String?
    }

    private let aiService: AIService
    init(aiService: AIService = .shared) { self.aiService = aiService }

    func classify(_ message: String, recentHistory: [ChatMessage]) async -> Intent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized(trimmed)

        if lower == "/project-status" { return .showProject(reference: nil) }
        if lower.hasPrefix("/project-status ") { return .showProject(reference: String(trimmed.dropFirst("/project-status ".count))) }
        if lower.hasPrefix("/project-note ") {
            let text = String(trimmed.dropFirst("/project-note ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addNote(reference: nil, text: text)
        }
        if lower.hasPrefix("/project-decision ") {
            let text = String(trimmed.dropFirst("/project-decision ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addDecision(reference: nil, text: text, rationale: nil)
        }
        if lower.hasPrefix("/project-goal ") {
            let text = String(trimmed.dropFirst("/project-goal ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addGoal(reference: nil, text: text)
        }
        if lower.hasPrefix("/project-todo ") {
            let text = String(trimmed.dropFirst("/project-todo ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addPending(reference: nil, text: text)
        }
        if lower.hasPrefix("/project-done ") {
            let text = String(trimmed.dropFirst("/project-done ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .completePending(reference: nil, query: text)
        }
        if lower.hasPrefix("/project-deliverable ") {
            let text = String(trimmed.dropFirst("/project-deliverable ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addDeliverable(reference: nil, name: text, path: nil)
        }

        guard looksMemoryRelated(lower) else { return .none }

        let exactContinue = ["συνεχισε απο εκει που μειναμε", "παμε απο εκει που μειναμε", "συνεχισε εκει που μειναμε", "continue where we left off", "continue from where we left off"]
        if exactContinue.contains(lower) { return .continueLatest }

        let transcript = Array(recentHistory.suffix(6)).promptTranscript
        let prompt = """
        Είσαι intent extractor για persistent project memory του TRAVIS.

        Allowed intents ONLY:
        none, add_decision, add_note, add_goal, add_pending, complete_pending,
        add_deliverable, mark_deliverable_ready, show_project, continue_latest

        add_decision: canonical project decision.
        add_note: project-specific information/constraint/idea to retain.
        add_goal: explicit new project objective.
        add_pending: explicit unfinished task/open item.
        complete_pending: user says an existing open item is completed; text should identify it.
        add_deliverable: explicit planned output/artifact. text = deliverable name; path if user gives exact path.
        mark_deliverable_ready: user says a deliverable is ready/finished; text identifies it; path if available.
        show_project: asks for project context/status.
        continue_latest: asks to continue project work from where it stopped.
        none: ordinary question/action with no durable project-memory operation.

        Be conservative. Do not turn every sentence into memory.
        reference = project reference if explicitly given, else null.
        text = canonical content without filler phrases.

        Recent context:
        \(transcript)

        User message:
        \(message)

        Return JSON only:
        {"intent":"none","reference":null,"text":null,"rationale":null,"path":null}
        """

        guard let raw = try? await aiService.generateText(
            prompt: prompt,
            maxTokens: 420,
            context: AIInvocationContext(workload: .classification, capabilityId: "project_memory", operation: "classify")
        ), let decision = decode(raw) else { return .none }

        switch decision.intent {
        case "add_decision":
            guard let text = clean(decision.text) else { return .none }
            return .addDecision(reference: clean(decision.reference), text: text, rationale: clean(decision.rationale))
        case "add_note":
            guard let text = clean(decision.text) else { return .none }
            return .addNote(reference: clean(decision.reference), text: text)
        case "add_goal":
            guard let text = clean(decision.text) else { return .none }
            return .addGoal(reference: clean(decision.reference), text: text)
        case "add_pending":
            guard let text = clean(decision.text) else { return .none }
            return .addPending(reference: clean(decision.reference), text: text)
        case "complete_pending":
            guard let text = clean(decision.text) else { return .none }
            return .completePending(reference: clean(decision.reference), query: text)
        case "add_deliverable":
            guard let text = clean(decision.text) else { return .none }
            return .addDeliverable(reference: clean(decision.reference), name: text, path: clean(decision.path))
        case "mark_deliverable_ready":
            guard let text = clean(decision.text) else { return .none }
            return .markDeliverableReady(reference: clean(decision.reference), query: text, path: clean(decision.path))
        case "show_project": return .showProject(reference: clean(decision.reference))
        case "continue_latest": return .continueLatest
        default: return .none
        }
    }

    private func looksMemoryRelated(_ text: String) -> Bool {
        let hints = [
            "θυμη", "remember", "σημειω", "note", "αποφασ", "decision", "κρατα", "project", "προτζεκτ",
            "μειναμε", "continue", "συνεχισ", "στοχος", "goal", "εκκρεμ", "todo", "μενει", "remaining",
            "παραδοτε", "deliverable", "ολοκληρω", "finished", "ready"
        ]
        return hints.contains { text.contains($0) }
    }

    private func decode(_ raw: String) -> Decision? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
