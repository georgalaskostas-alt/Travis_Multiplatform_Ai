import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
final class LocalProductivityCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_productivity"
    let name = "Local Productivity"
    let capabilityDescription = "Zero-token local clipboard and system-information operations, with approval before clipboard mutations."
    let keywords: [String] = [
        "clipboard", "copy to clipboard", "read clipboard", "προχειρο", "πρόχειρο",
        "αντιγραψε στο προχειρο", "αντίγραψε στο πρόχειρο", "system info", "device info", "στοιχεια συστηματος", "στοιχεία συστήματος"
    ]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .productivity,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly, .localMutation],
                permissionKeys: [],
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard let invocation = parseDeterministically(command) else {
            return .reply("Για local productivity operations χρειάζομαι σαφή εντολή, π.χ. «διάβασε το πρόχειρο», «γράψε Χ στο πρόχειρο» ή «δείξε στοιχεία συστήματος».")
        }
        return try await handle(invocation: invocation)
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        guard invocation.capabilityId == id else {
            return .reply("Το structured invocation δεν ανήκει στο local_productivity capability.")
        }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        switch invocation.operation {
        case "clipboard_read":
            #if os(macOS)
            let value = NSPasteboard.general.string(forType: .string) ?? ""
            return .reply(value.isEmpty ? "Το πρόχειρο δεν περιέχει κείμενο." : "CLIPBOARD\n\n\(String(value.prefix(20_000)))")
            #else
            return .reply("Clipboard read υποστηρίζεται προς το παρόν στο macOS build.")
            #endif

        case "clipboard_write":
            guard let text = invocation.arguments["text"], !text.isEmpty else {
                return .reply("Δεν υπάρχει κείμενο για εγγραφή στο πρόχειρο.")
            }
            let payload = ClipboardPayload(text: text)
            let data = try JSONEncoder().encode(payload)
            guard let payloadText = String(data: data, encoding: .utf8) else {
                return .reply("Απέτυχε η προετοιμασία clipboard proposal.")
            }
            return .proposal(ProposedAction(
                capabilityId: id,
                summary: "Write text to clipboard",
                reasoning: "Η εγγραφή στο clipboard είναι local mutation και απαιτεί explicit approval.",
                expectedImpact: "Θα αντικατασταθεί το τρέχον κείμενο του clipboard με \(min(text.count, 20_000)) χαρακτήρες.",
                riskLevel: .low,
                payload: payloadText,
                filename: nil,
                location: "system clipboard"
            ))

        case "system_info":
            return .reply(renderSystemInfo())

        default:
            return .reply("Μη υποστηριζόμενη local productivity operation: \(invocation.operation)")
        }
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let raw = action.payload,
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) else { return }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(payload.text, forType: .string)
        onExecutionUpdate?(success ? "✅ Το clipboard ενημερώθηκε." : "❌ Η εγγραφή στο clipboard απέτυχε.")
        #else
        onExecutionUpdate?("❌ Clipboard write δεν υποστηρίζεται σε αυτό το build.")
        #endif
    }

    private struct ClipboardPayload: Codable {
        let text: String
    }

    private func parseDeterministically(_ command: String) -> DeterministicCapabilityInvocation? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()

        let readMarkers = ["read clipboard", "show clipboard", "διαβασε το προχειρο", "δειξε το προχειρο"]
        if readMarkers.contains(where: { normalized.contains($0) }) {
            return DeterministicCapabilityInvocation(capabilityId: id, operation: "clipboard_read")
        }

        let systemMarkers = ["system info", "device info", "στοιχεια συστηματος", "πληροφοριες συστηματος"]
        if systemMarkers.contains(where: { normalized.contains($0) }) {
            return DeterministicCapabilityInvocation(capabilityId: id, operation: "system_info")
        }

        let writePrefixes = ["copy to clipboard ", "write to clipboard ", "γραψε στο προχειρο ", "αντιγραψε στο προχειρο "]
        for prefix in writePrefixes {
            if let range = normalized.range(of: prefix) {
                let wordCountBefore = normalized[..<range.upperBound].split(whereSeparator: { $0.isWhitespace }).count
                let originalWords = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard originalWords.count >= wordCountBefore else { continue }
                let text = originalWords.dropFirst(wordCountBefore).joined(separator: " ")
                if !text.isEmpty {
                    return DeterministicCapabilityInvocation(
                        capabilityId: id,
                        operation: "clipboard_write",
                        arguments: ["text": text]
                    )
                }
            }
        }
        return nil
    }

    private func renderSystemInfo() -> String {
        let process = ProcessInfo.processInfo
        let memoryGB = Double(process.physicalMemory) / 1_073_741_824.0
        return """
        LOCAL SYSTEM INFO

        OS: \(process.operatingSystemVersionString)
        processors: \(process.processorCount)
        active processors: \(process.activeProcessorCount)
        physical memory: \(String(format: "%.1f", memoryGB)) GB
        host: \(process.hostName)

        Generated locally with 0 AI tokens.
        """
    }
}
