import Foundation

/// Classifies assistant-level control intent before ordinary capability routing.
/// It never performs the action itself; mutating actions remain deterministic
/// in TRAVISAppState after the task reference is resolved.
@MainActor
final class SystemIntentRouter {
    enum Intent: Hashable {
        case none
        case listTasks
        case taskStatus(String?)
        case taskLog(String?)
        case run(String?)
        case auto(String?)
        case resume(String?)
        case retry(String?)
        case cancel(String?)
        case schedulerCycle
        case aiUsage
        case aiModels
    }

    private struct Decision: Decodable {
        let intent: String
        let reference: String?
    }

    private let aiService: AIService
    init(aiService: AIService = .shared) { self.aiService = aiService }

    func classify(_ message: String, recentHistory: [ChatMessage]) async -> Intent {
        if let explicit = explicitCommand(message) { return explicit }
        guard looksLikeRuntimeControl(message) else { return .none }

        let transcript = Array(recentHistory.suffix(6)).promptTranscript
        let prompt = """
        Είσαι deterministic intent classifier για τον TRAVIS.
        Τα επιτρεπτά intents είναι ΜΟΝΟ:
        none, list_tasks, task_status, task_log, run, auto, resume, retry, cancel, scheduler_cycle.

        Αναγνώρισε assistant/runtime control μόνο όταν ο χρήστης πραγματικά ζητά έλεγχο autonomous task.
        Κανονικές ερωτήσεις, project work, trading analysis, coding, research ή δημιουργία περιεχομένου => none.
        Το reference πρέπει να κρατά όσο γίνεται αυτούσια την αναφορά του χρήστη στο task.

        Πρόσφατο context:
        \(transcript)

        Μήνυμα:
        \(message)

        Απάντησε μόνο JSON:
        {"intent":"none","reference":null}
        """

        guard let raw = try? await aiService.generateText(prompt: prompt),
              let decision = decode(raw) else { return .none }
        return map(decision)
    }

    private func looksLikeRuntimeControl(_ message: String) -> Bool {
        let text = message.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
        let markers = [
            "task", "autonomous", "runtime", "scheduler", "checkpoint", "log",
            "resume", "retry", "cancel", "continue", "run it", "run the",
            "συνεχ", "ξανατρε", "επανεκτελ", "ακυρ", "σταματα", "σταματησε",
            "αποτυχη", "ολοκληρω", "προηγουμενο task", "εργασια που", "τρεχει"
        ]
        return markers.contains { text.contains($0) }
    }

    private func explicitCommand(_ message: String) -> Intent? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let commands: [(String, (String?) -> Intent)] = [
            ("/task-status", { .taskStatus($0) }),
            ("/task-log", { .taskLog($0) }),
            ("/resume", { .resume($0) }),
            ("/retry", { .retry($0) }),
            ("/cancel", { .cancel($0) }),
            ("/auto", { .auto($0) }),
            ("/run", { .run($0) })
        ]
        if lower == "/tasks" { return .listTasks }
        if lower == "/scheduler-run" { return .schedulerCycle }
        if lower == "/ai-usage" { return .aiUsage }
        if lower == "/ai-models" { return .aiModels }
        for (command, make) in commands {
            if lower == command { return make(nil) }
            if lower.hasPrefix(command + " ") {
                let ref = String(trimmed.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return make(ref.isEmpty ? nil : ref)
            }
        }
        return nil
    }

    private func decode(_ raw: String) -> Decision? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }

    private func map(_ decision: Decision) -> Intent {
        switch decision.intent {
        case "list_tasks": return .listTasks
        case "task_status": return .taskStatus(decision.reference)
        case "task_log": return .taskLog(decision.reference)
        case "run": return .run(decision.reference)
        case "auto": return .auto(decision.reference)
        case "resume": return .resume(decision.reference)
        case "retry": return .retry(decision.reference)
        case "cancel": return .cancel(decision.reference)
        case "scheduler_cycle": return .schedulerCycle
        default: return .none
        }
    }
}
