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

    /// The standing-permission key gating any file save, regardless of
    /// destination — see `PersistenceService.isPermissionGranted`/
    /// `setPermission`. The same generic model is meant to be reused for
    /// other standing mandates later (e.g. trading), keyed differently.
    private static let filePermissionKey = "file_save"

    /// Set when a save_file request had no filename — the generated text is
    /// held here until the user's next message supplies one.
    private var pendingContent: String?
    private var pendingOriginalCommand: String?
    private var pendingLocation: String?

    /// A fully-specified save_file request that's on hold waiting for the
    /// user to answer the one-time "may I save files?" consent question.
    private struct PendingSaveRequest {
        let command: String
        let content: String
        let filename: String
        let location: String?
    }
    private var pendingPermissionRequest: PendingSaveRequest?

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        if let content = pendingContent {
            return resolvePendingFilename(from: command, content: content)
        }

        if let pending = pendingPermissionRequest {
            return try await resolvePermissionConsent(reply: command, pending: pending, recentHistory: recentHistory)
        }

        status = .running
        defer { status = .idle }

        let historyBlock = recentHistory.isEmpty ? "" : """

        Πρόσφατο ιστορικό συνομιλίας (για context, ώστε να καταλαβαίνεις αναφορές όπως "αυτό", "σχετικά", "συνέχισε"):
        \(recentHistory.promptTranscript)

        """

        let prompt = """
        Είσαι ο προσωπικός βοηθός TRAVIS. \(historyBlock)Ο χρήστης έγραψε τώρα: "\(command)"

        Απόφασε ποια από τις τρεις περιπτώσεις ισχύει:
        - "reply": απλή συζήτηση, ερώτηση, ή chit-chat. Καμία ενέργεια δεν χρειάζεται, μόνο απάντηση. Αυτή είναι η προεπιλογή — διάλεξέ την εκτός αν ο χρήστης ζητάει ρητά κάτι από τις παρακάτω κατηγορίες.
        - "save_file": ρητό αίτημα να γραφτεί κείμενο ΚΑΙ να αποθηκευτεί σε αρχείο (π.χ. "γράψε το και αποθήκευσέ το", "φτιάξε μου αρχείο με...", "θέλω ένα αρχείο με...").
        - "revoke_file_permission": ρητή δήλωση ότι ο χρήστης αφαιρεί/ανακαλεί την άδεια που είχε δώσει στον TRAVIS να αποθηκεύει αρχεία (π.χ. "δεν έχεις πια άδεια να αποθηκεύεις", "ανάκαλεσε την άδεια αποθήκευσης αρχείων").

        ΣΗΜΑΝΤΙΚΟ: Οι άδειες αποθήκευσης αρχείων αποθηκεύονται μόνιμα σε βάση δεδομένων, ανεξάρτητα από τη συνομιλία ή το session — ΠΟΤΕ μην απαντήσεις (στο "content") ότι δεν έχεις πρόσβαση σε προηγούμενες συνομιλίες/ρυθμίσεις ή ότι "κάθε συνομιλία ξεκινά από μηδενική βάση". Αν κάτι πράγματι δεν είναι γνωστό, πες το συγκεκριμένα.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο, markdown ή εξήγηση πριν ή μετά, ακριβώς σε αυτή τη μορφή (το "content" μπορεί να είναι κενό string αν kind είναι "revoke_file_permission"):
        {"kind": "reply, save_file, ή revoke_file_permission", "content": "η απάντηση (αν reply) ή το πλήρες κείμενο προς αποθήκευση (αν save_file), στα ελληνικά"}
        """

        let raw = try await aiService.generateText(prompt: prompt)

        guard let decision = Self.parseDecision(from: raw) else {
            // Δεν μπορέσαμε να παρσάρουμε το JSON — δείξε το ωμό κείμενο σαν απλή απάντηση,
            // ώστε ο χρήστης να πάρει πάντα κάποια απόκριση αντί για σιωπή.
            return .reply(raw)
        }

        switch decision.kind {
        case "revoke_file_permission":
            PersistenceService.shared.setPermission(Self.filePermissionKey, granted: false)
            return .reply("Εντάξει — ανακάλεσα την άδεια αποθήκευσης αρχείων. Θα σε ξαναρωτήσω πριν αποθηκεύσω κάτι.")

        case "save_file":
            let extraction = try await FileSaveRequestExtractor.extract(from: command, aiService: aiService)
            guard let filename = extraction.filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pendingContent = decision.content
                pendingOriginalCommand = command
                pendingLocation = extraction.location
                return .reply("Τι όνομα να δώσω στο αρχείο, και πού να το αποθηκεύσω;")
            }
            return proceedToSaveFile(command: command, content: decision.content, filename: filename, location: extraction.location)

        default:
            return .reply(decision.content)
        }
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

        return proceedToSaveFile(command: originalCommand, content: content, filename: reply, location: location)
    }

    /// Gate before any save_file proposal is built: if the standing
    /// "file_save" permission hasn't been granted yet, hold the fully
    /// resolved request and ask conversationally instead of proposing
    /// anything or touching the filesystem.
    private func proceedToSaveFile(command: String, content: String, filename: String, location: String?) -> CapabilityOutcome {
        guard PersistenceService.shared.isPermissionGranted(Self.filePermissionKey) else {
            pendingPermissionRequest = PendingSaveRequest(command: command, content: content, filename: filename, location: location)
            return .reply("Θα χρειαστώ την άδειά σου να αποθηκεύω αρχεία — μου τη δίνεις;")
        }

        return .proposal(makeProposedAction(command: command, content: content, filename: filename, location: location))
    }

    /// Interprets the user's free-text reply to the consent question via
    /// the AI (not a keyword match). On agreement, grants the standing
    /// permission and — macOS only — acquires the one-time home-directory
    /// bookmark before finally building the proposal that was on hold.
    private func resolvePermissionConsent(reply: String, pending: PendingSaveRequest, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        pendingPermissionRequest = nil

        let historyBlock = recentHistory.isEmpty ? "" : """
        Πρόσφατο ιστορικό συνομιλίας (για context):
        \(recentHistory.promptTranscript)

        """

        let consentPrompt = """
        \(historyBlock)Ο χρήστης απάντησε: "\(reply)" σε ερώτηση αν δίνει άδεια στον TRAVIS να αποθηκεύει αρχεία.
        Ερμήνευσε αν πρόκειται για καταφατική απάντηση (δίνει την άδεια) ή όχι.
        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με τη λέξη yes ή no, χωρίς τίποτα άλλο.
        """
        let raw = try await aiService.generateText(prompt: consentPrompt)
        let agreed = raw.lowercased().contains("yes")

        guard agreed else {
            return .reply("Εντάξει, δεν θα αποθηκεύσω το αρχείο.")
        }

        PersistenceService.shared.setPermission(Self.filePermissionKey, granted: true)

        #if os(macOS)
        guard FileLocationService.shared.requestHomeDirectoryAccess() else {
            return .reply("Δεν δόθηκε πρόσβαση στον φάκελο, οπότε δεν μπόρεσα να αποθηκεύσω το αρχείο. Μπορείς να το ξαναζητήσεις.")
        }
        #endif

        return .proposal(makeProposedAction(command: pending.command, content: pending.content, filename: pending.filename, location: pending.location))
    }

    private func makeProposedAction(command: String, content: String, filename: String, location: String?) -> ProposedAction {
        let sanitized = FileSaveRequestExtractor.sanitizeFilename(filename)
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
