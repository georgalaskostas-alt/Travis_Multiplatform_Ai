import Foundation

@MainActor
final class GoalIntentRouter {
    enum Intent: Hashable {
        case none
        case createProject(title: String, goal: String)
        case continueProject(reference: String)
        case listProjects
    }

    private struct Decision: Decodable {
        let intent: String
        let title: String?
        let goal: String?
        let reference: String?
    }

    private let aiService: AIService
    init(aiService: AIService = .shared) { self.aiService = aiService }

    func classify(_ message: String, recentHistory: [ChatMessage]) async -> Intent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized(trimmed)

        if lower == "/projects" { return .listProjects }
        if lower.hasPrefix("/project ") {
            let goal = String(trimmed.dropFirst("/project ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return goal.isEmpty ? .none : .createProject(title: suggestedTitle(from: goal), goal: goal)
        }

        guard looksProjectRelated(lower) else { return .none }

        let transcript = Array(recentHistory.suffix(6)).promptTranscript
        let prompt = """
        Είσαι intent classifier για έναν premium general-purpose assistant.
        Αναγνώρισε ΜΟΝΟ project/workspace intent.

        Allowed intents:
        none, create_project, continue_project, list_projects

        create_project = ο χρήστης θέλει να ξεκινήσει/σχεδιάσει/χτίσει ένα project, app, startup, product, system ή πολυβηματική κατασκευή που χρειάζεται συνέχεια.
        continue_project = ζητά να συνεχίσουμε συγκεκριμένο υπάρχον project.
        list_projects = ζητά λίστα projects.
        none = απλή ερώτηση, analysis, trading question, one-off coding question, casual chat.

        Πρόσφατο context:
        \(transcript)

        Μήνυμα:
        \(message)

        Return JSON only:
        {"intent":"none","title":null,"goal":null,"reference":null}
        """

        guard let raw = try? await aiService.generateText(prompt: prompt, maxTokens: 350),
              let decision = decode(raw) else { return .none }

        switch decision.intent {
        case "create_project":
            let goal = decision.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGoal = (goal?.isEmpty == false) ? goal! : trimmed
            let title = decision.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .createProject(title: (title?.isEmpty == false) ? title! : suggestedTitle(from: resolvedGoal), goal: resolvedGoal)
        case "continue_project":
            guard let ref = decision.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return .none }
            return .continueProject(reference: ref)
        case "list_projects": return .listProjects
        default: return .none
        }
    }

    private func looksProjectRelated(_ text: String) -> Bool {
        let hints = ["project", "προτζεκτ", "εργο", "app", "εφαρμογ", "startup", "προιον", "product", "χτισ", "φτιαξ", "σχεδιασ", "build", "develop", "αναπτυξ"]
        return hints.contains { text.contains($0) }
    }

    private func decode(_ raw: String) -> Decision? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }

    private func suggestedTitle(from goal: String) -> String {
        let words = goal.split(separator: " ").prefix(8).joined(separator: " ")
        return words.isEmpty ? "New Project" : words
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
    }
}
