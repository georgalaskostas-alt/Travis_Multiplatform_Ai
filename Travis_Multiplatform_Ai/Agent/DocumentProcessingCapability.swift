import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
final class DocumentProcessingCapability: AgentCapability {
    let id = "document_processing"
    let name = "Document Processing"
    let capabilityDescription = "Αναλύει, συνοψίζει και εξάγει πληροφορία από πραγματικά αρχεία που έχει καταγράψει ο TRAVIS, με υποστήριξη text/JSON/CSV/Markdown και PDF text extraction."
    let keywords: [String] = [
        "σύνοψη αρχείου", "συνοψη αρχειου", "ανάλυσε το pdf", "αναλυσε το pdf",
        "διάβασε το pdf", "διαβασε το pdf", "document", "summarize file", "extract from file", "pdf"
    ]
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
                timeoutSeconds: 150,
                maxAttempts: 2
            )
        )
    }

    private let persistence: PersistenceService
    private let aiService: AIService
    private let maxDocumentCharacters = 140_000

    init(persistence: PersistenceService = .shared, aiService: AIService = .shared) {
        self.persistence = persistence
        self.aiService = aiService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let files = persistence.loadFiles().sorted { $0.createdAt > $1.createdAt }
        guard !files.isEmpty else {
            return .reply("Δεν υπάρχουν ακόμη tracked documents στον TRAVIS.")
        }

        guard let selected = try await selectFile(command: command, files: files) else {
            return .reply("Δεν μπόρεσα να ταυτοποιήσω με ασφάλεια ποιο tracked document εννοείς.")
        }

        let url = URL(fileURLWithPath: selected.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .reply("Το tracked document δεν υπάρχει πλέον στο path: \(selected.path)")
        }

        let extracted = try extractText(from: url)
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .reply("Δεν βρέθηκε αναγνώσιμο text layer στο document \(selected.filename).")
        }

        let clipped = String(extracted.prefix(maxDocumentCharacters))
        let truncation = extracted.count > clipped.count
            ? "\n[DOCUMENT CONTENT TRUNCATED AT \(maxDocumentCharacters) CHARACTERS]"
            : ""

        let prompt = """
        You are TRAVIS's document-processing component.
        Answer the CURRENT USER REQUEST using only the supplied document content and recent conversation context.
        Do not invent facts not present in the document.
        If requested information is absent or content was truncated before it could be verified, state that limitation explicitly.
        Preserve important numbers, dates, names, headings and technical terminology exactly when relevant.

        DOCUMENT
        filename: \(selected.filename)
        path: \(selected.path)

        RECENT CONTEXT
        \(recentHistory.suffix(5).promptTranscript)

        CURRENT USER REQUEST
        \(command)

        DOCUMENT CONTENT
        \(clipped)
        \(truncation)
        """

        let result = try await aiService.generateText(prompt: prompt, maxTokens: 5000)
        return .reply("DOCUMENT RESULT — \(selected.filename)\n\n\(result)")
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability.
    }

    private func selectFile(command: String, files: [PersistedFile]) async throws -> PersistedFile? {
        let normalized = command.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
        let direct = files.filter { file in
            let filename = file.filename.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
            return filename.count >= 3 && normalized.contains(filename)
        }
        if direct.count == 1 { return direct[0] }

        let inventory = files.prefix(80).enumerated().map { index, file in
            "D\(index + 1) | \(file.filename) | \(file.path)"
        }.joined(separator: "\n")
        let prompt = """
        Select one document from this exact inventory for the user's request.
        Return JSON only: {"id":"D1"}. Never invent an ID.

        USER REQUEST
        \(command)

        INVENTORY
        \(inventory)
        """
        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 250)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              id.hasPrefix("D"),
              let index = Int(id.dropFirst()),
              index >= 1,
              index <= min(files.count, 80) else { return nil }
        return files[index - 1]
    }

    private func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml", "swift", "py", "js", "ts", "html", "css":
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
            return ""

        case "pdf":
            #if canImport(PDFKit)
            guard let document = PDFDocument(url: url) else { return "" }
            var pages: [String] = []
            pages.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
                pages.append("--- PAGE \(index + 1) ---\n\(text)")
                if pages.joined(separator: "\n\n").count >= maxDocumentCharacters { break }
            }
            return pages.joined(separator: "\n\n")
            #else
            return "PDF text extraction is unavailable on this platform build."
            #endif

        default:
            return ""
        }
    }
}
