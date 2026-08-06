import Foundation

/// Handles conversational messages and text-writing requests. Keywords are
/// intentionally empty — this is the default/catch-all capability for now,
/// since deciding "just talk" vs "actually do something" is itself the job
/// of a single AI call, not something a keyword gate upstream can pre-filter.
///
/// `@MainActor` because this type holds mutable state (`pendingContent`)
/// across separate `handle()` calls while it waits for the user to answer
/// "what filename?" — without actor isolation, two rapidly-sent messages
/// could race on that state.
@MainActor
final class TextTaskCapability: AgentCapability {
    let id = "text_task"
    let name = "Text Task"
    let capabilityDescription = "Απαντάει σε ερωτήσεις/συζήτηση σαν κανονικό chat μήνυμα, ή γράφει και προτείνει αποθήκευση κειμένου σε αρχείο όταν ζητηθεί ρητά."
    let keywords: [String] = []
    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService

    /// Set when a save_file request had no filename — the generated text is
    /// held here until the user's next message supplies one.
    private var pendingContent: String?
    private var pendingOriginalCommand: String?
    private var pendingLocation: String?

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String) async throws -> CapabilityOutcome {
        if let content = pendingContent {
            return resolvePendingFilename(from: command, content: content)
        }

        status = .running
        defer { status = .idle }

        let prompt = """
        Είσαι ο προσωπικός βοηθός TRAVIS. Ο χρήστης έγραψε: "\(command)"

        Απόφασε ποια από τις δύο περιπτώσεις ισχύει:
        - "reply": απλή συζήτηση, ερώτηση, ή chit-chat. Καμία ενέργεια δεν χρειάζεται, μόνο απάντηση. Αυτή είναι η προεπιλογή — διάλεξέ την εκτός αν ο χρήστης ζητάει ρητά κάτι από την παρακάτω κατηγορία.
        - "save_file": ρητό αίτημα να γραφτεί κείμενο ΚΑΙ να αποθηκευτεί σε αρχείο (π.χ. "γράψε το και αποθήκευσέ το", "φτιάξε μου αρχείο με...", "θέλω ένα αρχείο με...").

        Αν είναι "save_file" ΚΑΙ ο χρήστης ανέφερε ρητά συγκεκριμένο όνομα αρχείου στην εντολή του (π.χ. "αποθήκευσέ το με όνομα Χ"), βάλε αυτό το όνομα στο πεδίο "filename" (χωρίς κατάληξη .txt). Αν δεν ανέφερε όνομα, το "filename" πρέπει να είναι null — ΜΗΝ επινοήσεις όνομα μόνος σου.

        Αν είναι "save_file" ΚΑΙ ο χρήστης ανέφερε ρητά μια τοποθεσία αποθήκευσης (π.χ. "στο desktop", "στα Documents", ή ένα συγκεκριμένο path), βάλε αυτή την τοποθεσία στο πεδίο "location" ακριβώς όπως την περιέγραψε. Αν δεν ανέφερε τοποθεσία, το "location" πρέπει να είναι null — ΜΗΝ υποθέσεις τοποθεσία μόνος σου.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο, markdown ή εξήγηση πριν ή μετά, ακριβώς σε αυτή τη μορφή:
        {"kind": "reply ή save_file", "filename": "το όνομα αρχείου ή null", "location": "η τοποθεσία αποθήκευσης ή null", "content": "η απάντηση (αν reply) ή το πλήρες κείμενο προς αποθήκευση (αν save_file), στα ελληνικά"}
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

        guard let filename = decision.filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingContent = decision.content
            pendingOriginalCommand = command
            pendingLocation = decision.location
            return .reply("Τι όνομα να δώσω στο αρχείο, και πού να το αποθηκεύσω;")
        }

        return .proposal(makeProposedAction(command: command, content: decision.content, filename: filename, location: decision.location))
    }

    func resolve(_ action: ProposedAction) {
        // Η αποθήκευση του παραγόμενου κειμένου γίνεται από το ChatView κατά το approve.
    }

    private func resolvePendingFilename(from reply: String, content: String) -> CapabilityOutcome {
        pendingContent = nil
        let originalCommand = pendingOriginalCommand ?? content
        pendingOriginalCommand = nil
        let location = pendingLocation
        pendingLocation = nil

        return .proposal(makeProposedAction(command: originalCommand, content: content, filename: reply, location: location))
    }

    private func makeProposedAction(command: String, content: String, filename: String, location: String?) -> ProposedAction {
        let sanitized = Self.sanitizeFilename(filename)
        let alreadyExists = Self.fileAlreadyExists(named: sanitized)
        let locationSuffix = location.map { " στο \"\($0)\"" } ?? ""

        let summary = alreadyExists
            ? "Δημιουργία κειμένου: \"\(command)\" — Υπάρχει ήδη αρχείο με αυτό το όνομα, θα αντικατασταθεί"
            : "Δημιουργία κειμένου: \"\(command)\""

        let reasoning = alreadyExists
            ? "Η εντολή ζητάει ρητά δημιουργία και αποθήκευση κειμένου, οπότε κάλεσα το AI για να το γράψει. Υπάρχει ήδη αρχείο με το όνομα \"\(sanitized)\" — η αποθήκευση θα το αντικαταστήσει. Πρόκειται για αναστρέψιμη ενέργεια σε τοπικό αρχείο, χωρίς άλλη επίδραση στο σύστημα."
            : "Η εντολή ζητάει ρητά δημιουργία και αποθήκευση κειμένου, οπότε κάλεσα το AI για να το γράψει. Πρόκειται για αναστρέψιμη ενέργεια — απλή αποθήκευση σε τοπικό αρχείο, χωρίς καμία άλλη επίδραση στο σύστημα."

        let expectedImpact = alreadyExists
            ? "Θα αντικατασταθεί το υπάρχον αρχείο με όνομα \"\(sanitized)\"\(locationSuffix)."
            : "Θα αποθηκευτεί αρχείο με όνομα \"\(sanitized)\"\(locationSuffix)."

        return ProposedAction(
            capabilityId: id,
            summary: summary,
            reasoning: reasoning,
            expectedImpact: expectedImpact,
            riskLevel: .low,
            payload: content,
            filename: sanitized,
            location: location
        )
    }

    /// Checks both the persisted file history and the actual on-disk
    /// Documents directory, since a file could exist on disk without a
    /// persisted record (e.g. created before this persistence layer existed).
    private static func fileAlreadyExists(named filename: String) -> Bool {
        if PersistenceService.shared.fileExists(named: filename) {
            return true
        }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }

        return FileManager.default.fileExists(atPath: documentsURL.appendingPathComponent(filename).path)
    }

    private static func parseDecision(from text: String) -> (kind: String, filename: String?, location: String?, content: String)? {
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

        return (kind, object["filename"] as? String, object["location"] as? String, content)
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: CharacterSet(charactersIn: "/\\")).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            name = "travis-text-\(Int(Date().timeIntervalSince1970))"
        }

        if !name.lowercased().hasSuffix(".txt") {
            name += ".txt"
        }

        return name
    }
}
