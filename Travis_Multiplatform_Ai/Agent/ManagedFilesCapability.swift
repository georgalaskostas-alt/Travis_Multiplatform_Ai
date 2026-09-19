import Foundation

/// Read-only access to files already created and tracked by TRAVIS.
/// It does not scan arbitrary user folders and does not request new filesystem access.
@MainActor
final class ManagedFilesCapability: AgentCapability {
    let id = "managed_files"
    let name = "Managed Files"
    let capabilityDescription = "Λίστα και ανάγνωση αρχείων που έχει ήδη δημιουργήσει και καταγράψει ο TRAVIS, χωρίς αυθαίρετη σάρωση του filesystem."
    let keywords: [String] = ["αρχεία του travis", "αρχεια του travis", "managed files", "διάβασε το αρχείο", "διαβασε το αρχειο", "άνοιξε το αρχείο", "ανοιξε το αρχειο"]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .files,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 45,
                maxAttempts: 2
            )
        )
    }

    private let persistence: PersistenceService
    private let aiService: AIService

    init(persistence: PersistenceService = .shared, aiService: AIService = .shared) {
        self.persistence = persistence
        self.aiService = aiService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let files = persistence.loadFiles().sorted { $0.createdAt > $1.createdAt }
        guard !files.isEmpty else {
            return .reply("Ο TRAVIS δεν έχει ακόμη καταγεγραμμένα αρχεία που δημιούργησε ο ίδιος.")
        }

        let lower = command.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
        if lower.contains("λίστα") || lower.contains("λιστα") || lower.contains("ποια αρχεια") || lower.contains("managed files") {
            let rows = files.prefix(50).map { file in
                "- \(file.filename) — \(file.path) — created by \(file.capabilityId)"
            }.joined(separator: "\n")
            return .reply("TRAVIS MANAGED FILES\n\n\(rows)")
        }

        let selectionPrompt = """
        Select exactly one file from the inventory that best matches the user's request.
        Never invent a path. Return JSON only: {"path":"exact inventory path"}

        USER REQUEST
        \(command)

        INVENTORY
        \(files.prefix(80).map { "\($0.filename) | \($0.path)" }.joined(separator: "\n"))
        """
        let raw = try await aiService.generateText(prompt: selectionPrompt, maxTokens: 300)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let selectionData = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: selectionData) as? [String: Any],
              let selectedPath = object["path"] as? String,
              files.contains(where: { $0.path == selectedPath }) else {
            return .reply("Δεν μπόρεσα να ταυτοποιήσω με ασφάλεια ποιο καταγεγραμμένο αρχείο εννοείς.")
        }

        let url = URL(fileURLWithPath: selectedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .reply("Το αρχείο είναι καταγεγραμμένο αλλά δεν υπάρχει πλέον στο αποθηκευμένο path: \(selectedPath)")
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize ?? 0
        guard size <= 2_000_000 else {
            return .reply("Το αρχείο είναι \(size) bytes και είναι πολύ μεγάλο για άμεση ανάγνωση στο chat. Θα χρειαστεί document-processing pipeline.")
        }

        let fileData = try Data(contentsOf: url)
        guard let text = String(data: fileData, encoding: .utf8) else {
            return .reply("Το αρχείο υπάρχει αλλά δεν είναι UTF-8 text. Θα το χειριστούμε από το document-processing capability.")
        }

        return .reply("FILE: \(url.lastPathComponent)\nPATH: \(selectedPath)\n\n\(String(text.prefix(120_000)))")
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability.
    }
}