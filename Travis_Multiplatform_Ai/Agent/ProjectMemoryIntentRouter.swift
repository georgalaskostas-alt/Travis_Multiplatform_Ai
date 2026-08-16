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
        case showProject(reference: String?)
        case continueLatest
    }

    private struct Decision: Decodable {
        let intent: String
        let reference: String?
        let text: String?
        let rationale: String?
    }

    private let aiService: AIService
    init(aiService: AIService = .shared) { self.aiService = aiService }

    func classify(_ message: String, recentHistory: [ChatMessage]) async -> Intent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized(trimmed)

        if lower == "/project-status" { return .showProject(reference: nil) }
        if lower.hasPrefix("/project-status ") {
            return .showProject(reference: String(trimmed.dropFirst("/project-status ".count)))
        }
        if lower.hasPrefix("/project-note ") {
            let text = String(trimmed.dropFirst("/project-note ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addNote(reference: nil, text: text)
        }
        if lower.hasPrefix("/project-decision ") {
            let text = String(trimmed.dropFirst("/project-decision ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .none : .addDecision(reference: nil, text: text, rationale: nil)
        }

        guard looksMemoryRelated(lower) else { return .none }

        // Ultra-common continuation phrases are deterministic and need no API call.
        let exactContinue = [
            "συνεχισε απο εκει που μειναμε", "παμε απο εκει που μειναμε",
            "συνεχισε εκει που μειναμε", "continue where we left off",
            "continue from where we left off"
        ]
        if exactContinue.contains(lower) { return .continueLatest }

        let transcript = Array(recentHistory.suffix(6)).promptTranscript
        let prompt = """
        Είσαι intent extractor για persistent project memory του TRAVIS.

        Allowed intents ONLY:
        none, add_decision, add_note, show_project, continue_latest

        add_decision: ο χρήστης δηλώνει απόφαση που πρέπει να παραμείνει canonical για project, π.χ. «αποφασίσαμε να χρησιμοποιήσουμε SwiftUI».
        add_note: ο χρήστης ζητά να θυμόμαστε project-specific πληροφορία/constraint/idea.
        show_project: ζητά κατάσταση/context ενός project.
        continue_latest: ζητά γενικά να συνεχίσουμε από εκεί που μείναμε χωρίς να ονομάζει task.
        none: απλή ερώτηση ή action που δεν είναι project-memory operation.

        Μην μετατρέπεις κάθε πρόταση σε memory. Απαιτείται σαφής πρόθεση να κρατηθεί ως απόφαση/note ή να συνεχιστεί project work.
        reference = project reference αν δίνεται, αλλιώς null.
        text = καθαρή canonical πρόταση χωρίς φράσεις τύπου «θυμήσου ότι».

        Recent context:
        \(transcript)

        User message:
        \(message)

        Return JSON only:
        {"intent":"none","reference":null,"text":null,"rationale":null}
        """

        guard let raw = try? await aiService.generateText(prompt: prompt, maxTokens: 350),
              let decision = decode(raw) else { return .none }

        switch decision.intent {
        case "add_decision":
            guard let text = clean(decision.text), !text.isEmpty else { return .none }
            return .addDecision(reference: clean(decision.reference), text: text, rationale: clean(decision.rationale))
        case "add_note":
            guard let text = clean(decision.text), !text.isEmpty else { return .none }
            return .addNote(reference: clean(decision.reference), text: text)
        case "show_project": return .showProject(reference: clean(decision.reference))
        case "continue_latest": return .continueLatest
        default: return .none
        }
    }

    private func looksMemoryRelated(_ text: String) -> Bool {
        let hints = [
            "θυμη", "remember", "σημειω", "note", "αποφασ", "decision",
            "κρατα", "project", "προτζεκτ", "μειναμε", "continue", "συνεχισ"
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
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
