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
        if let local = deterministicNaturalIntent(message, now: now) { return local }
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

    /// Conservative local parser for common schedules. It handles only explicit
    /// relative intervals and simple daily/hourly recurrences; ambiguous calendar
    /// language falls through to the AI parser.
    private func deterministicNaturalIntent(_ message: String, now: Date) -> Intent? {
        let original = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = normalize(original)
        guard !text.isEmpty else { return nil }

        if ["δειξε schedules", "δειξε τα schedules", "show schedules", "list schedules"].contains(text) {
            return .list
        }
        if ["τρεξε τα due schedules", "run due schedules", "run scheduled work now"].contains(text) {
            return .runDue
        }

        let cancelPrefixes = ["cancel schedule ", "ακυρωσε schedule ", "ακυρωσε το schedule "]
        for prefix in cancelPrefixes where text.hasPrefix(prefix) {
            let ref = originalReference(afterWordCount: prefix.split(separator: " ").count, from: original)
            return ref.isEmpty ? nil : .cancel(reference: ref)
        }

        if let relative = parseRelativeSchedule(text, original: original, now: now) {
            return relative
        }
        if let recurring = parseSimpleRecurrence(text, original: original, now: now) {
            return recurring
        }
        return nil
    }

    private func parseRelativeSchedule(_ text: String, original: String, now: Date) -> Intent? {
        // Supported examples: "run task X in 20 minutes", "τρεξε το task X σε 2 ωρες".
        let units: [(markers: [String], seconds: Double)] = [
            ([" minutes", " minute", " λεπτα", " λεπτο"], 60),
            ([" hours", " hour", " ωρες", " ωρα"], 3_600),
            ([" days", " day", " μερες", " μερα"], 86_400)
        ]

        for unit in units {
            for marker in unit.markers {
                guard let markerRange = text.range(of: marker) else { continue }
                let before = String(text[..<markerRange.lowerBound])
                let tokens = before.split(separator: " ")
                guard let numberToken = tokens.last,
                      let amount = Double(numberToken), amount > 0 else { continue }

                let relativeMarkers = [" in ", " σε ", " μετα απο "]
                guard relativeMarkers.contains(where: { before.contains($0) }) else { continue }

                let seconds = max(60, amount * unit.seconds)
                let runAt = now.addingTimeInterval(seconds)
                let reference = extractTaskReferenceBeforeRelativePhrase(original)
                return .schedule(taskReference: reference, runAt: runAt, recurrenceSeconds: nil)
            }
        }
        return nil
    }

    private func parseSimpleRecurrence(_ text: String, original: String, now: Date) -> Intent? {
        let dailyMarkers = ["every day", "καθε μερα"]
        if dailyMarkers.contains(where: { text.contains($0) }) {
            return .schedule(
                taskReference: extractTaskReferenceBeforeRecurrence(original),
                runAt: now.addingTimeInterval(86_400),
                recurrenceSeconds: 86_400
            )
        }

        let hourlyMarkers = ["every hour", "καθε ωρα"]
        if hourlyMarkers.contains(where: { text.contains($0) }) {
            return .schedule(
                taskReference: extractTaskReferenceBeforeRecurrence(original),
                runAt: now.addingTimeInterval(3_600),
                recurrenceSeconds: 3_600
            )
        }
        return nil
    }

    private func extractTaskReferenceBeforeRelativePhrase(_ original: String) -> String? {
        let normalized = normalize(original)
        let separators = [" in ", " σε ", " μετα απο "]
        guard let separator = separators.compactMap({ normalized.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let prefixLength = normalized.distance(from: normalized.startIndex, to: separator.lowerBound)
        let originalIndex = original.index(original.startIndex, offsetBy: min(prefixLength, original.count))
        let prefix = String(original[..<originalIndex])
        return cleanTaskReference(prefix)
    }

    private func extractTaskReferenceBeforeRecurrence(_ original: String) -> String? {
        let normalized = normalize(original)
        let markers = [" every day", " καθε μερα", " every hour", " καθε ωρα"]
        guard let marker = markers.compactMap({ normalized.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let prefixLength = normalized.distance(from: normalized.startIndex, to: marker.lowerBound)
        let originalIndex = original.index(original.startIndex, offsetBy: min(prefixLength, original.count))
        return cleanTaskReference(String(original[..<originalIndex]))
    }

    private func cleanTaskReference(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "run task ", "run the task ", "schedule task ",
            "τρεξε task ", "τρεξε το task ", "προγραμματισε task ", "προγραμματισε το task "
        ]
        let normalized = normalize(result)
        for prefix in prefixes where normalized.hasPrefix(prefix) {
            let count = min(prefix.count, result.count)
            result = String(result.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return result.isEmpty ? nil : result
    }

    private func originalReference(afterWordCount count: Int, from original: String) -> String {
        let words = original.split(whereSeparator: { $0.isWhitespace })
        guard words.count > count else { return "" }
        return words.dropFirst(count).joined(separator: " ")
    }

    private func looksLikeScheduling(_ message: String) -> Bool {
        let text = normalize(message)
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

    private func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
