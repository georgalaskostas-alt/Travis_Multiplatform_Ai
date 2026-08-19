import Foundation

/// Extra conservative zero-model routes for capabilities that already support
/// structured deterministic execution. This is intentionally strict: when the
/// input cannot be represented exactly, it returns nil and the normal path is used.
@MainActor
final class ExpandedDeterministicCommandRouter {
    static let shared = ExpandedDeterministicCommandRouter()

    func invocation(for command: String, capabilities: [AgentCapability]) -> DeterministicCapabilityInvocation? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        let available = Set(capabilities.map(\.id))

        if available.contains("local_text_transform"),
           let invocation = textTransform(command: command, normalized: normalized) {
            return invocation
        }
        if available.contains("local_productivity"),
           let invocation = productivity(command: command, normalized: normalized) {
            return invocation
        }
        return nil
    }

    private func textTransform(command: String, normalized: String) -> DeterministicCapabilityInvocation? {
        let operation: String
        if normalized.contains("uppercase") || normalized.contains("κεφαλαι") {
            operation = "uppercase"
        } else if normalized.contains("lowercase") || normalized.contains("πεζα") || normalized.contains("πεζά") {
            operation = "lowercase"
        } else if normalized.contains("trim text") || normalized.contains("trim whitespace") || normalized.contains("κοψε κενα") || normalized.contains("κόψε κενά") {
            operation = "trim"
        } else if normalized.contains("sort unique lines") || normalized.contains("sort and unique") || normalized.contains("ταξινομησε μοναδικες γραμμες") || normalized.contains("ταξινόμησε μοναδικές γραμμές") {
            operation = "sort_unique_lines"
        } else if normalized.contains("sort lines") || normalized.contains("ταξινομησε γραμμες") || normalized.contains("ταξινόμησε γραμμές") {
            operation = "sort_lines"
        } else if normalized.contains("unique lines") || normalized.contains("remove duplicate lines") || normalized.contains("μοναδικες γραμμες") || normalized.contains("μοναδικές γραμμές") {
            operation = "unique_lines"
        } else if normalized.contains("replace") || normalized.contains("αντικαταστ") {
            operation = "replace"
        } else {
            return nil
        }

        let quoted = quotedValues(in: command)
        let dependencyText = firstDependencyTextBinding(in: command)

        var arguments: [String: String] = [:]
        if operation == "replace" {
            guard quoted.count >= 2 else { return nil }
            if let dependencyText {
                arguments["text"] = dependencyText
                arguments["find"] = quoted[0]
                arguments["replace"] = quoted[1]
            } else {
                guard quoted.count >= 3 else { return nil }
                arguments["text"] = quoted[0]
                arguments["find"] = quoted[1]
                arguments["replace"] = quoted[2]
            }
        } else {
            if let dependencyText {
                arguments["text"] = dependencyText
            } else {
                guard let text = quoted.first else { return nil }
                arguments["text"] = text
            }
        }

        return DeterministicCapabilityInvocation(
            capabilityId: "local_text_transform",
            operation: operation,
            arguments: arguments
        )
    }

    private func productivity(command: String, normalized: String) -> DeterministicCapabilityInvocation? {
        let readMarkers = ["read clipboard", "show clipboard", "διαβασε το προχειρο", "δειξε το προχειρο"]
        if readMarkers.contains(where: { normalized.contains($0) }) {
            return DeterministicCapabilityInvocation(capabilityId: "local_productivity", operation: "clipboard_read")
        }

        let systemMarkers = ["system info", "device info", "στοιχεια συστηματος", "πληροφοριες συστηματος"]
        if systemMarkers.contains(where: { normalized.contains($0) }) {
            return DeterministicCapabilityInvocation(capabilityId: "local_productivity", operation: "system_info")
        }

        let writeMarkers = ["copy to clipboard", "write to clipboard", "γραψε στο προχειρο", "αντιγραψε στο προχειρο"]
        guard writeMarkers.contains(where: { normalized.contains($0) }) else { return nil }

        if let dependencyText = firstDependencyTextBinding(in: command) {
            return DeterministicCapabilityInvocation(
                capabilityId: "local_productivity",
                operation: "clipboard_write",
                arguments: ["text": dependencyText]
            )
        }
        guard let text = quotedValues(in: command).first, !text.isEmpty else { return nil }
        return DeterministicCapabilityInvocation(
            capabilityId: "local_productivity",
            operation: "clipboard_write",
            arguments: ["text": text]
        )
    }

    /// Keeps dependency handling exact. We only accept the already-supported
    /// structured binding syntax and never infer which previous step to use.
    private func firstDependencyTextBinding(in text: String) -> String? {
        let pattern = #"\{\{dep:\d+:text\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private func quotedValues(in text: String) -> [String] {
        let pattern = #"[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
