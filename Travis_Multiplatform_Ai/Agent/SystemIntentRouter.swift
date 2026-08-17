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
        case localIntelligence
        case trainingDataset
        case trainingPolicy
        case localModelRegistry
        case trainingRuns
        case trainingStart(kind: String, name: String, baseModel: String)
        case trainingRefresh(reference: String)
        case trainingCancel(reference: String)
        case trainingPromote(candidateReference: String, inferenceModelId: String)
        case trainingRollback(candidateReference: String, reason: String)
    }

    private struct Decision: Decodable {
        let intent: String
        let reference: String?
    }

    private let aiService: AIService
    init(aiService: AIService = .shared) { self.aiService = aiService }

    func classify(_ message: String, recentHistory: [ChatMessage]) async -> Intent {
        if let explicit = explicitCommand(message) { return explicit }
        if let local = deterministicNaturalIntent(message) { return local }
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

    private func deterministicNaturalIntent(_ message: String) -> Intent? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = normalize(trimmed)

        if ["δειξε τα tasks", "δειξε tasks", "list tasks", "show tasks", "ποια tasks υπαρχουν"].contains(text) {
            return .listTasks
        }
        if ["τρεξε τον scheduler", "τρεξε scheduler", "run scheduler", "run scheduler cycle"].contains(text) {
            return .schedulerCycle
        }
        if ["δειξε ai usage", "ai usage", "δειξε κοστος ai", "show ai usage"].contains(text) {
            return .aiUsage
        }
        if ["δειξε ai models", "ai models", "show ai models"].contains(text) {
            return .aiModels
        }
        if ["local intelligence", "δειξε local intelligence", "local metrics", "δειξε local metrics"].contains(text) {
            return .localIntelligence
        }
        if ["training dataset", "δειξε training dataset", "training data", "δειξε training data"].contains(text) {
            return .trainingDataset
        }
        if ["training policy", "δειξε training policy", "local training policy"].contains(text) {
            return .trainingPolicy
        }
        if ["local model registry", "δειξε local model", "active local model"].contains(text) {
            return .localModelRegistry
        }
        if ["training runs", "δειξε training runs", "local training runs"].contains(text) {
            return .trainingRuns
        }

        let patterns: [(prefixes: [String], make: (String?) -> Intent)] = [
            (["resume ", "συνεχισε task ", "συνεχισε το task "], { .resume($0) }),
            (["retry ", "ξανατρεξε task ", "ξανατρεξε το task "], { .retry($0) }),
            (["cancel ", "ακυρωσε task ", "ακυρωσε το task "], { .cancel($0) }),
            (["auto ", "τρεξε αυτοματα task ", "τρεξε αυτοματα το task "], { .auto($0) }),
            (["run task ", "τρεξε task ", "τρεξε το task "], { .run($0) }),
            (["status task ", "κατασταση task ", "δειξε status task "], { .taskStatus($0) }),
            (["log task ", "δειξε log task ", "ιστορικο task "], { .taskLog($0) })
        ]

        for pattern in patterns {
            for prefix in pattern.prefixes where text.hasPrefix(prefix) {
                let normalizedReference = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let originalReference = bestEffortOriginalReference(normalizedReference, from: trimmed)
                return pattern.make(originalReference.isEmpty ? nil : originalReference)
            }
        }

        if ["resume it", "συνεχισε το", "συνεχισε το task"].contains(text) { return .resume(nil) }
        if ["retry it", "ξανατρεξε το", "ξανατρεξε το task"].contains(text) { return .retry(nil) }
        if ["run it", "τρεξε το", "τρεξε το task"].contains(text) { return .run(nil) }
        if ["auto run it", "τρεξε το αυτοματα"].contains(text) { return .auto(nil) }
        if ["cancel it", "ακυρωσε το", "σταματα το task"].contains(text) { return .cancel(nil) }

        return nil
    }

    private func looksLikeRuntimeControl(_ message: String) -> Bool {
        let text = normalize(message)
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
        if lower == "/local-intelligence" { return .localIntelligence }
        if lower == "/training-data" { return .trainingDataset }
        if lower == "/training-policy" { return .trainingPolicy }
        if lower == "/local-model" { return .localModelRegistry }
        if lower == "/training-runs" { return .trainingRuns }

        if lower.hasPrefix("/train-local ") {
            let parts = splitCommandArguments(String(trimmed.dropFirst("/train-local ".count)), expected: 3)
            guard parts.count == 3 else { return .none }
            return .trainingStart(kind: parts[0], name: parts[1], baseModel: parts[2])
        }
        if lower.hasPrefix("/training-refresh ") {
            let ref = String(trimmed.dropFirst("/training-refresh ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.isEmpty ? .none : .trainingRefresh(reference: ref)
        }
        if lower.hasPrefix("/training-cancel ") {
            let ref = String(trimmed.dropFirst("/training-cancel ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.isEmpty ? .none : .trainingCancel(reference: ref)
        }
        if lower.hasPrefix("/training-promote ") {
            let parts = splitCommandArguments(String(trimmed.dropFirst("/training-promote ".count)), expected: 2)
            guard parts.count == 2 else { return .none }
            return .trainingPromote(candidateReference: parts[0], inferenceModelId: parts[1])
        }
        if lower.hasPrefix("/training-rollback ") {
            let remainder = String(trimmed.dropFirst("/training-rollback ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = remainder.split(separator: " ", maxSplits: 1).map(String.init)
            guard !pieces.isEmpty else { return .none }
            return .trainingRollback(candidateReference: pieces[0], reason: pieces.count > 1 ? pieces[1] : "Manual rollback")
        }

        for (command, make) in commands {
            if lower == command { return make(nil) }
            if lower.hasPrefix(command + " ") {
                let ref = String(trimmed.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return make(ref.isEmpty ? nil : ref)
            }
        }
        return nil
    }

    private func splitCommandArguments(_ value: String, expected: Int) -> [String] {
        // Quoted arguments allow model names/labels containing spaces while
        // keeping the control path deterministic and AI-free.
        var output: [String] = []
        var current = ""
        var quote: Character?

        for char in value {
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
            } else if char.isWhitespace {
                if !current.isEmpty {
                    output.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { output.append(current) }

        if output.count <= expected { return output }
        let head = Array(output.prefix(expected - 1))
        return head + [output.dropFirst(expected - 1).joined(separator: " ")]
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

    private func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bestEffortOriginalReference(_ normalizedReference: String, from original: String) -> String {
        guard !normalizedReference.isEmpty else { return "" }
        let words = original.split(whereSeparator: { $0.isWhitespace })
        let referenceWordCount = normalizedReference.split(separator: " ").count
        guard referenceWordCount > 0, words.count >= referenceWordCount else { return normalizedReference }
        return words.suffix(referenceWordCount).joined(separator: " ")
    }
}
