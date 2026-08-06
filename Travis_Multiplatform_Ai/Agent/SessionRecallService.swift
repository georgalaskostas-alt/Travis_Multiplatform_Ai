import Foundation

enum SessionRecallOutcome {
    case notRecall
    case found(UUID)
    case notFound
}

/// Detects "bring back an old conversation" requests (e.g. "φέρε μου τη
/// συνομιλία από χθες") before `AgentOrchestrator` ever routes a message to
/// a capability — this is a system-level UI action, not a task any
/// capability should see, so it has to be checked ahead of capability
/// dispatch rather than inside one. Interpreted via the AI (it does the
/// date arithmetic for "χθες"/"την Τρίτη"/etc.), never via keyword
/// matching.
@MainActor
final class SessionRecallService {
    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func evaluate(_ message: String, excluding liveSessionId: UUID) async throws -> SessionRecallOutcome {
        let today = Self.dateFormatter.string(from: Date())

        let prompt = """
        Σημερινή ημερομηνία: \(today)
        Ο χρήστης έγραψε: "\(message)"

        Είναι αυτό ένα ρητό αίτημα να δει/φέρει μπροστά μια ΠΡΟΗΓΟΥΜΕΝΗ συνομιλία (π.χ. "φέρε μου τη συνομιλία από χθες", "δείξε μου τι λέγαμε την Τρίτη", "άνοιξε την προηγούμενη συζήτηση"); ΟΧΙ απλή αναφορά στο παρελθόν μέσα σε μια κανονική ερώτηση ή εντολή;

        Αν ΝΑΙ, υπολόγισε σε ποια ημερομηνία αναφέρεται με βάση τη σημερινή ημερομηνία και βάλε τη στο πεδίο "date" σε μορφή YYYY-MM-DD. Αν αναφέρεται γενικά στην "προηγούμενη συνομιλία" χωρίς συγκεκριμένη ημερομηνία, βάλε "date": "previous".
        Αν ΟΧΙ, βάλε "isRecall": false και "date": null.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο: {"isRecall": true ή false, "date": "YYYY-MM-DD", "previous", ή null}
        """

        let raw = try await aiService.generateText(prompt: prompt)

        guard let decision = Self.parseDecision(from: raw), decision.isRecall, let dateString = decision.date else {
            return .notRecall
        }

        let candidates = PersistenceService.shared.loadChatSessions().filter { $0.id != liveSessionId }

        if dateString == "previous" {
            guard let mostRecent = candidates.first else { return .notFound }
            return .found(mostRecent.id)
        }

        guard let targetDate = Self.dateFormatter.date(from: dateString) else { return .notFound }
        let calendar = Calendar.current
        guard let match = candidates.first(where: { calendar.isDate($0.startedAt, inSameDayAs: targetDate) }) else {
            return .notFound
        }
        return .found(match.id)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }()

    private static func parseDecision(from text: String) -> (isRecall: Bool, date: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jsonStart = trimmed.firstIndex(of: "{"),
            let jsonEnd = trimmed.lastIndex(of: "}"),
            jsonStart < jsonEnd
        else { return nil }

        let jsonSubstring = trimmed[jsonStart...jsonEnd]

        guard
            let data = jsonSubstring.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let isRecall = object["isRecall"] as? Bool
        else { return nil }

        return (isRecall, object["date"] as? String)
    }
}
