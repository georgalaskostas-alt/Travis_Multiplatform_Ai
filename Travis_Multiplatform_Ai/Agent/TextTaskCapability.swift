import Foundation

/// Handles conversational messages and text-writing requests. Keywords are
/// intentionally empty — this is the default/catch-all capability for now,
/// since deciding "just talk" vs "actually do something" is itself the job
/// of a single AI call, not something a keyword gate upstream can pre-filter.
final class TextTaskCapability: AgentCapability {
    let id = "text_task"
    let name = "Text Task"
    let capabilityDescription = "Απαντάει σε ερωτήσεις/συζήτηση σαν κανονικό chat μήνυμα, ή γράφει και προτείνει αποθήκευση κειμένου σε αρχείο όταν ζητηθεί ρητά."
    let keywords: [String] = []
    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let prompt = """
        Είσαι ο προσωπικός βοηθός TRAVIS. Ο χρήστης έγραψε: "\(command)"

        Απόφασε ποια από τις δύο περιπτώσεις ισχύει:
        - "reply": απλή συζήτηση, ερώτηση, ή chit-chat. Καμία ενέργεια δεν χρειάζεται, μόνο απάντηση. Αυτή είναι η προεπιλογή — διάλεξέ την εκτός αν ο χρήστης ζητάει ρητά κάτι από την παρακάτω κατηγορία.
        - "save_file": ρητό αίτημα να γραφτεί κείμενο ΚΑΙ να αποθηκευτεί σε αρχείο (π.χ. "γράψε το και αποθήκευσέ το", "φτιάξε μου αρχείο με...", "θέλω ένα αρχείο με...").

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο, markdown ή εξήγηση πριν ή μετά, ακριβώς σε αυτή τη μορφή:
        {"kind": "reply ή save_file", "content": "η απάντηση (αν reply) ή το πλήρες κείμενο προς αποθήκευση (αν save_file), στα ελληνικά"}
        """

        let raw = try await aiService.generateText(prompt: prompt)

        guard let decision = Self.parseDecision(from: raw) else {
            // Δεν μπορέσαμε να παρσάρουμε το JSON — δείξε το ωμό κείμενο σαν απλή απάντηση,
            // ώστε ο χρήστης να πάρει πάντα κάποια απόκριση αντί για σιωπή.
            return .reply(raw)
        }

        guard decision.kind == "save_file" else {
            return .reply(decision.content)
        }

        return .proposal(
            ProposedAction(
                capabilityId: id,
                summary: "Δημιουργία κειμένου: \"\(command)\"",
                reasoning: "Η εντολή ζητάει ρητά δημιουργία και αποθήκευση κειμένου, οπότε κάλεσα το AI για να το γράψει. Πρόκειται για αναστρέψιμη ενέργεια — απλή αποθήκευση σε τοπικό αρχείο, χωρίς καμία άλλη επίδραση στο σύστημα.",
                expectedImpact: "Θα αποθηκευτεί ένα νέο αρχείο .txt με το παραγόμενο κείμενο.",
                riskLevel: .low,
                payload: decision.content
            )
        )
    }

    func resolve(_ action: ProposedAction) {
        // Η αποθήκευση του παραγόμενου κειμένου γίνεται από το ChatView κατά το approve.
    }

    private static func parseDecision(from text: String) -> (kind: String, content: String)? {
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
            let kind = object["kind"] as? String,
            let content = object["content"] as? String
        else { return nil }

        return (kind, content)
    }
}
