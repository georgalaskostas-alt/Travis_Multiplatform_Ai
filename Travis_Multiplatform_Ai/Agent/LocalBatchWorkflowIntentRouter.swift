import Foundation

@MainActor
final class LocalBatchWorkflowIntentRouter {
    static let shared = LocalBatchWorkflowIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        guard let source = absolutePaths(in: goal).first,
              let ext = explicitExtension(in: goal),
              let transform = transformIntent(normalized: normalized, goal: goal) else { return nil }

        var batchArgs: [String: String] = [
            "sourcePath": source,
            "names": "{{dep:1:names}}",
            "transform": transform.operation
        ]
        if let destination = secondAbsolutePath(in: goal) { batchArgs["destinationPath"] = destination }
        if let find = transform.find { batchArgs["find"] = find }
        if let replace = transform.replace { batchArgs["replace"] = replace }

        let steps = [
            LocalWorkflowComposer.StepSpec(
                title: "Find the exact .\(ext) files for batch processing",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_file_search",
                    operation: "search",
                    arguments: ["path": source, "extension": ext, "recursive": "false", "limit": "1000"]
                ),
                successCriteria: ["Return the exact matching filenames as structured verified output."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "Prepare safe batch transform for the files found in step 1",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_batch_text",
                    operation: "transform_files",
                    arguments: batchArgs
                ),
                successCriteria: ["Prepare an approval-gated batch transform for exactly the verified filenames from step 1 without overwriting existing outputs."],
                riskLevel: .medium
            )
        ]

        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local batch file search → transform workflow (0 planner tokens)",
            steps: steps,
            capabilities: capabilities
        )
    }

    private func transformIntent(normalized: String, goal: String) -> (operation: String, find: String?, replace: String?)? {
        if normalized.contains("remove duplicate lines") || normalized.contains("unique lines") || (normalized.contains("διπλο") && normalized.contains("γραμμ")) {
            return ("unique_lines", nil, nil)
        }
        if normalized.contains("sort lines") || (normalized.contains("ταξινομ") && normalized.contains("γραμμ")) {
            return ("sort_lines", nil, nil)
        }
        if normalized.contains("normalize whitespace") || (normalized.contains("κανονικοποι") && normalized.contains("κενα")) {
            return ("normalize_whitespace", nil, nil)
        }
        if normalized.contains("pretty json") || normalized.contains("format json") || (normalized.contains("μορφοποι") && normalized.contains("json")) {
            return ("pretty_json", nil, nil)
        }
        if normalized.contains("replace") || normalized.contains("αντικαταστ") {
            let quoted = quotedValues(in: goal)
            guard quoted.count >= 2, !quoted[0].isEmpty else { return nil }
            return ("replace", quoted[0], quoted[1])
        }
        return nil
    }

    private func absolutePaths(in text: String) -> [String] {
        let pattern = #"/Users/[^\s\n\r\t,;]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}.!?"))
        }
    }

    private func secondAbsolutePath(in text: String) -> String? {
        let paths = absolutePaths(in: text)
        return paths.count >= 2 ? paths[1] : nil
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
}
