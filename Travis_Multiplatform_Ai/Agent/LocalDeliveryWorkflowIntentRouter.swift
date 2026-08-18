import Foundation

@MainActor
final class LocalDeliveryWorkflowIntentRouter {
    static let shared = LocalDeliveryWorkflowIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        let marker = ["delivery bundle", "delivery folder", "prepare delivery", "package files", "φάκελο παράδοσης", "πακετο αρχειων", "πακέτο αρχείων", "ετοιμασε παραδοση", "ετοίμασε παράδοση"].contains { normalized.contains($0) }
        guard marker else { return nil }

        let paths = absolutePaths(in: goal)
        guard paths.count >= 2, let ext = explicitExtension(in: goal) else { return nil }
        let quoted = quotedValues(in: goal)
        guard let bundleName = quoted.first, isSafeSimpleName(bundleName) else { return nil }

        let source = paths[0]
        let destination = paths[1]
        let specs = [
            LocalWorkflowComposer.StepSpec(
                title: "Find the requested .\(ext) files",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_file_search",
                    operation: "search",
                    arguments: ["path": source, "extension": ext, "recursive": normalized.contains("recursive") || normalized.contains("αναδρομ") ? "true" : "false", "limit": "2000"]
                ),
                successCriteria: ["Return the exact matching file names as structured verified output."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "Prepare delivery folder \(bundleName)",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_delivery_bundle",
                    operation: "create_bundle",
                    arguments: [
                        "sourcePath": source,
                        "destinationPath": destination,
                        "bundleName": bundleName,
                        "names": "{{dep:1:names}}"
                    ]
                ),
                successCriteria: ["Create an approval-gated delivery folder from exactly the verified file set, with a manifest and no overwrite."],
                riskLevel: .medium
            )
        ]
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Verified file search → delivery bundle workflow (0 planner tokens)",
            steps: specs,
            capabilities: capabilities
        )
    }

    private func absolutePaths(in text: String) -> [String] {
        let pattern = #"/Users/[^\s\n\r\t,;]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}.!?"))
        }
    }

    private func explicitExtension(in text: String) -> String? {
        let pattern = #"\.([A-Za-z0-9]{1,10})(?:\s|$|,|;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).lowercased()
    }

    private func quotedValues(in text: String) -> [String] {
        let pattern = #"[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("|")
    }
}
