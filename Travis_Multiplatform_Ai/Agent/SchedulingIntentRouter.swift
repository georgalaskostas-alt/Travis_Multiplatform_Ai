import Foundation

@MainActor
final class SchedulingIntentRouter {
    enum Intent: Hashable {
        case none
        case list
        case schedule(taskReference: String?, runAt: Date, recurrenceSeconds: TimeInterval?)
        case cancel(reference: String)
        case runDue
    }

    private struct Decision: Decodable {
        let intent: String
        let taskReference: String?
        let runAtISO8601: String?
        let recurrenceSeconds: Double?
        let scheduleReference: String?
    }

    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func classify(_ message: String, recentHistory: [ChatMessage], now: Date = Date()) async -> Intent {
        if let explicit = explicitCommand(message) { return explicit }
        guard looksLikeScheduling(message) else { return .none }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowText = formatter.string(from: now)
        let timeZone = TimeZone.current

        let prompt = """
        You are the scheduling intent parser for TRAVIS.
        Interpret dates/times in the DEVICE TIME ZONE: \(timeZone.identifier), GMT offset \(timeZone.secondsFromGMT(for: now)).
        CURRENT DEVICE TIME: \(nowText)

        Allowed intents only:
        none, list, schedule, cancel, run_due.

        A schedule request must target an existing autonomous task by the user's natural reference.
        Preserve taskReference as close as possible to the user's wording; do not invent a task ID.
        For schedule, convert the requested first execution time to an absolute ISO-8601 timestamp.
        recurrenceSeconds is null for one-shot work. For repeating work use the requested interval in seconds.
        Minimum supported recurrence is 60 seconds.
        If the user did not express a future/deferred time or recurrence, return none.
        scheduleReference is used only for cancelling a scheduled job (short ID/title/reference).

        RECENT CONTEXT
        \(recentHistory.suffix(6).promptTranscript)

        USER MESSAGE
        \(message)

        Return JSON only:
        {"intent":"none","taskReference":null,"runAtISO8601":null,"recurrenceSeconds":null,"scheduleReference":null}
        """

        guard let raw = try? await aiService.generateText(prompt: prompt, maxTokens: 500),
              let decision = decode(raw) else { return .none }

        switch decision.intent {
        case "list":
            return .list
        case "run_due":
            return .runDue
        case "cancel":
            guard let reference = decision.scheduleReference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return .none }
            return .cancel(reference: reference)
        case "schedule":
            guard let iso = decision.runAtISO8601,
                  let date = parseISO8601(iso) else { return .none }
            let recurrence = decision.recurrenceSeconds.map { max(60, $0) }
            return .schedule(taskReference: decision.taskReference, runAt: date, recurrenceSeconds: recurrence)
        default:
            return .none
        }
    }

    private func looksLikeScheduling(_ message: String) -> Bool {
        let text = message.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
        let markers = [
            "schedule", "scheduled", "later", "tomorrow", "tonight", "every day", "every hour", "weekly",
            "προγραμματ", "αργοτερα", "αυριο", "αποψε", "καθε μερα", "καθε ωρα", "εβδομαδ",
            "στις ", "σε μια ωρα", "σε 1 ωρα", "σε δυο ωρες", "μετα απο"
        ]
        return markers.contains { text.contains($0) }
    }

    private func explicitCommand(_ message: String) -> Intent? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "/schedules" { return .list }
        if lower == "/schedule-run-due" { return .runDue }
        if lower.hasPrefix("/schedule-cancel ") {
            let reference = String(trimmed.dropFirst("/schedule-cancel ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return reference.isEmpty ? .none : .cancel(reference: reference)
        }
        // Natural parser handles /schedule because it needs time interpretation.
        if lower.hasPrefix("/schedule ") { return nil }
        return nil
    }

    private func decode(_ raw: String) -> Decision? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
