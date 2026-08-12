import Foundation

/// Lets TRAVIS propose improvements/fixes to its OWN codebase — it never
/// applies anything itself. Every proposal is an ordinary `ProposedAction`
/// that, once approved, only ever writes the generated Claude Code prompt
/// out as a text file via the same file-save flow `TextTaskCapability`
/// uses. Nothing here runs code, touches git, or modifies any project
/// file directly — there is no execution path from this type to the
/// actual codebase at all, only to a `.txt` file the user copies from
/// manually.
///
/// "TRAVIS decides on its own that something needs improving" (per the
/// spec this was built against) happens inside the AI classification
/// call in `handle()`, using `recentHistory` — e.g. recognizing a bug
/// the user has now mentioned more than once. It is not a separate,
/// unprompted background trigger: like every other capability, this one
/// only ever runs in response to a routed user message (see `keywords`).
/// Over-triggering on an unrelated message is low-risk by design: the
/// classification step itself checks whether the request is genuinely
/// about TRAVIS's own code and falls back to an ordinary conversational
/// reply otherwise, exactly like `TextTaskCapability`'s default path.
///
/// `@MainActor` for the same reason as `TextTaskCapability`/
/// `CryptoTradingCapability`: holds mutable state across separate
/// `handle()` calls while waiting on the one-time file-save consent
/// question.
@MainActor
final class SelfImprovementCapability: AgentCapability {
    let id = "self_improvement"
    let name = "Self-Improvement"
    let capabilityDescription = "Προτείνει βελτιώσεις/διορθώσεις στον ίδιο τον κώδικα του TRAVIS σαν ProposedAction που χρειάζεται ρητή έγκριση κάθε φορά· ποτέ δεν εκτελεί ή τροποποιεί κώδικα μόνο του."
    let keywords: [String] = [
        "παρατήρησα", "διόρθωσε", "διορθώσεις", "διόρθωση", "διορθώσει",
        "βελτίωσε", "βελτιώσεις", "βελτίωση", "βελτιστοποίησε", "βελτιστοποίηση",
        "bug", "σφάλμα του travis", "πρόβλημα με τον travis", "πρόβλημα με το travis",
        "φτιάξε τον κώδικα", "φτιάξε το travis", "άλλαξε τον κώδικα", "αλλαγή στον κώδικα",
        "αυτοβελτίωση"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService

    /// The exact same standing-permission key `TextTaskCapability` gates
    /// its file saves on — the generated prompt is written out through
    /// the identical flow (`TRAVISAppState.saveGeneratedText`), so it's
    /// gated identically. This is about filesystem write consent only;
    /// it says nothing about whether any given proposal gets approved —
    /// see the note on `riskLevel` in `makeProposedAction`.
    private static let filePermissionKey = "file_save"

    /// A fully-generated improvement proposal on hold waiting for the
    /// user to answer the one-time "may I save files?" consent question.
    private struct PendingProposal {
        let summary: String
        let reasoning: String
        let prompt: String
        let riskLevel: RiskLevel
        let filename: String
    }
    private var pendingPermissionRequest: PendingProposal?

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        if let pending = pendingPermissionRequest {
            return try await resolvePermissionConsent(reply: command, pending: pending, recentHistory: recentHistory)
        }

        status = .running
        defer { status = .idle }

        let historyBlock = recentHistory.isEmpty ? "" : """

        Πρόσφατο ιστορικό συνομιλίας (χρησιμοποίησέ το για να αναγνωρίσεις αν πρόκειται για επαναλαμβανόμενο θέμα που έχει ξαναναφερθεί, ή για context σε αναφορές όπως "αυτό", "το ίδιο πρόβλημα"):
        \(recentHistory.promptTranscript)

        """

        let prompt = """
        Είσαι ο TRAVIS, προσωπικός AI βοηθός. Ο ίδιος ο TRAVIS είναι μια εφαρμογή SwiftUI (iOS/macOS), της οποίας ο πηγαίος κώδικας αναπτύσσεται από τον χρήστη σε συνεργασία με το Claude Code. \(historyBlock)Ο χρήστης έγραψε τώρα: "\(command)"

        Έλεγξε αν πρόκειται για ΓΝΗΣΙΟ αίτημα/παρατήρηση για βελτίωση ή διόρθωση της ΙΔΙΑΣ της εφαρμογής TRAVIS (π.χ. bug που ανέφερε, κάτι που θα ήθελε να δουλεύει διαφορετικά, επαναλαμβανόμενο πρόβλημα που φαίνεται στο ιστορικό) — ΟΧΙ κάτι άσχετο που απλά περιέχει παρόμοιες λέξεις (π.χ. "διόρθωσε την ώρα στο ρολόι" δεν αφορά τον κώδικα του TRAVIS).

        Αν ΔΕΝ πρόκειται για γνήσιο αίτημα βελτίωσης του ίδιου του TRAVIS, απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με JSON: {"isGenuine": false, "reply": "σύντομη φυσιολογική απάντηση στα ελληνικά σε ό,τι είπε ο χρήστης"}

        Αν ΕΙΝΑΙ γνήσιο αίτημα, απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με JSON σε αυτή τη μορφή, χωρίς κανένα άλλο κείμενο πριν ή μετά:
        {
          "isGenuine": true,
          "summary": "μία πρόταση, στα ελληνικά, τι θα διορθωθεί/βελτιωθεί",
          "reasoning": "2-3 προτάσεις στα ελληνικά: τι πρόβλημα εντοπίστηκε (ανάφερε αν είναι επαναλαμβανόμενο, βάσει του ιστορικού) και γιατί η προτεινόμενη προσέγγιση είναι λογική",
          "riskLevel": "medium ή high — high αν η αλλαγή αφορά κάτι ευαίσθητο (π.χ. entitlements/permissions, persistence schema, ασφάλεια, οικονομική/trading λογική), αλλιώς medium",
          "claudeCodePrompt": "ΠΛΗΡΕΣ, αναλυτικό prompt στα ελληνικά, έτοιμο να δοθεί απευθείας στο Claude Code — ΟΧΙ γενικόλογο. Πρέπει να περιλαμβάνει: (1) ακριβή περιγραφή του προβλήματος/της αλλαγής, με αριθμημένα βήματα όπου έχει νόημα, (2) ρητή οδηγία να κάνει πρώτα git fetch και merge --ff-only με το origin branch πριν αγγίξει οτιδήποτε, (3) ρητή οδηγία να ακολουθήσει τα υπάρχοντα patterns/conventions του project αντί να εισάγει νέα, (4) ρητή οδηγία να τρέξει τον καθιερωμένο target-membership έλεγχο (brace/paren balance σε project.pbxproj και σε όλα τα Swift αρχεία, occurrence-count έλεγχο για τυχόν νέα object IDs, single-native-target έλεγχο) πριν από οποιοδήποτε commit, (5) ρητή οδηγία για commit με περιγραφικό μήνυμα και push. Γράψε το με την ίδια λεπτομέρεια και ύφος που θα είχε μια πραγματική εντολή χρήστη προς το Claude Code."
        }
        """

        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 2048)

        guard let decision = Self.parseDecision(from: raw) else {
            return .reply(raw)
        }

        guard
            decision.isGenuine,
            let summary = decision.summary,
            let reasoning = decision.reasoning,
            let claudeCodePrompt = decision.claudeCodePrompt
        else {
            return .reply(decision.reply ?? "Δεν κατάλαβα ποια βελτίωση εννοείς.")
        }

        // Never `.low`, regardless of what the AI returned — enforced here,
        // not just requested in the prompt, per the requirement that every
        // code-change proposal needs a deliberate, non-trivial approval.
        let riskLevel: RiskLevel = (decision.riskLevel?.lowercased() == "high") ? .high : .medium

        return proceedToPropose(summary: summary, reasoning: reasoning, prompt: claudeCodePrompt, riskLevel: riskLevel)
    }

    func resolve(_ action: ProposedAction) {
        // Reject: nothing to do — ApprovalGateService already recorded it
        // in history. Approve: the actual file write happens generically
        // in TRAVISAppState.saveGeneratedText for any ProposedAction with
        // a payload, the same as TextTaskCapability. No standing mandate
        // exists for approval itself — every proposal here needs its own
        // explicit Approve, regardless of whether a similar one was
        // approved before; nothing in this type or ApprovalGateService
        // auto-approves anything.
    }

    private func proceedToPropose(summary: String, reasoning: String, prompt: String, riskLevel: RiskLevel) -> CapabilityOutcome {
        let filename = Self.filename(from: summary)

        guard PersistenceService.shared.isPermissionGranted(Self.filePermissionKey) else {
            pendingPermissionRequest = PendingProposal(summary: summary, reasoning: reasoning, prompt: prompt, riskLevel: riskLevel, filename: filename)
            return .reply("Θα χρειαστώ την άδειά σου να αποθηκεύω αρχεία, ώστε να σου δώσω το prompt έτοιμο σε αρχείο — μου τη δίνεις;")
        }

        return .proposal(makeProposedAction(summary: summary, reasoning: reasoning, prompt: prompt, riskLevel: riskLevel, filename: filename))
    }

    /// Interprets the user's free-text reply to the consent question via
    /// the AI (not a keyword match) — identical approach to
    /// `TextTaskCapability.resolvePermissionConsent`.
    private func resolvePermissionConsent(reply: String, pending: PendingProposal, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
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
            return .reply("Εντάξει, δεν θα αποθηκεύσω το prompt.")
        }

        PersistenceService.shared.setPermission(Self.filePermissionKey, granted: true)

        #if os(macOS)
        guard FileLocationService.shared.requestHomeDirectoryAccess() else {
            return .reply("Δεν δόθηκε πρόσβαση στον φάκελο, οπότε δεν μπόρεσα να αποθηκεύσω το αρχείο. Μπορείς να το ξαναζητήσεις.")
        }
        #endif

        return .proposal(makeProposedAction(
            summary: pending.summary, reasoning: pending.reasoning, prompt: pending.prompt,
            riskLevel: pending.riskLevel, filename: pending.filename
        ))
    }

    private func makeProposedAction(summary: String, reasoning: String, prompt: String, riskLevel: RiskLevel, filename: String) -> ProposedAction {
        ProposedAction(
            capabilityId: id,
            summary: "Πρόταση βελτίωσης κώδικα: \(summary)",
            reasoning: reasoning,
            expectedImpact: "ΔΕΝ θα εκτελεστεί ή τροποποιηθεί τίποτα αυτόματα — μόνο θα αποθηκευτεί το prompt σε αρχείο \"\(filename)\", έτοιμο να το δώσεις εσύ στο Claude Code χειροκίνητα.",
            riskLevel: riskLevel,
            payload: prompt,
            filename: filename,
            location: nil
        )
    }

    private static func filename(from summary: String) -> String {
        let words = summary
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "el"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")

        let base = words.isEmpty ? "travis-self-improvement" : "travis-fix-\(words)"
        return "\(base)-\(Int(Date().timeIntervalSince1970)).txt"
    }

    private static func parseDecision(from text: String) -> (isGenuine: Bool, summary: String?, reasoning: String?, riskLevel: String?, claudeCodePrompt: String?, reply: String?)? {
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
            let isGenuine = object["isGenuine"] as? Bool
        else { return nil }

        return (
            isGenuine,
            object["summary"] as? String,
            object["reasoning"] as? String,
            object["riskLevel"] as? String,
            object["claudeCodePrompt"] as? String,
            object["reply"] as? String
        )
    }
}
