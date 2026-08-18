import Foundation

/// Builds exact local workflows that turn verified local analysis into a saved
/// artifact. Folder-report requests are delegated first; CSV/JSON requests are
/// handled directly here. Ambiguous requests return nil.
@MainActor
final class LocalDataArtifactWorkflowIntentRouter {
    static let shared = LocalDataArtifactWorkflowIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        if let folderPlan = LocalDirectoryArtifactWorkflowIntentRouter.shared.plan(for: goal, capabilities: capabilities) {
            return folderPlan
        }

        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        guard normalized.contains("save") || normalized.contains("write") || normalized.contains("αποθηκευσ") || normalized.contains("σωσε") || normalized.contains("σώσε") else { return nil }

        let paths = absolutePaths(in: goal)
        guard paths.count >= 2 else { return nil }
        let source = paths[0]
        let target = paths[1]
        guard ["csv", "json"].contains(URL(fileURLWithPath: source).pathExtension.lowercased()) else { return nil }

        let targetURL = URL(fileURLWithPath: target)
        let filename = targetURL.lastPathComponent
        guard !filename.isEmpty, !targetURL.pathExtension.isEmpty else { return nil }

        guard let dataInvocation = dataInvocation(goal: goal, normalized: normalized, source: source) else { return nil }
        let specs = [
            LocalWorkflowComposer.StepSpec(
                title: "Process the requested data locally",
                invocation: dataInvocation,
                successCriteria: ["Produce the requested CSV/JSON result locally and expose it as structured text output."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "Save the verified data result as \(filename)",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_artifact",
                    operation: "write_new",
                    arguments: [
                        "directory": targetURL.deletingLastPathComponent().path,
                        "filename": filename,
                        "text": "{{dep:1:text}}"
                    ]
                ),
                successCriteria: ["Prepare creation of a new artifact containing exactly the verified result from step 1, with no overwrite."],
                riskLevel: .medium
            )
        ]
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local data processing → saved artifact workflow (0 planner tokens)",
            steps: specs,
            capabilities: capabilities
        )
    }

    private func dataInvocation(goal: String, normalized: String, source: String) -> DeterministicCapabilityInvocation? {
        let ext = URL(fileURLWithPath: source).pathExtension.lowercased()
        let quoted = quotedValues(in: goal)
        var args = ["path": source]

        if ext == "csv" {
            if normalized.contains("summary") || normalized.contains("συνοψη") || normalized.contains("σύνοψη") || normalized.contains("περιληψη") {
                return .init(capabilityId: "local_data", operation: "csv_summary", arguments: args)
            }
            if normalized.contains("average") || normalized.contains("mean") || normalized.contains("median") || normalized.contains("numeric stats") || normalized.contains("μεσο ορο") || normalized.contains("μέσο όρο") {
                guard let column = quoted.first, !column.isEmpty else { return nil }
                args["column"] = column
                return .init(capabilityId: "local_data", operation: "csv_numeric_stats", arguments: args)
            }
            if normalized.contains("group by") || normalized.contains("group count") || normalized.contains("ομαδοποι") {
                guard let column = quoted.first, !column.isEmpty else { return nil }
                args["column"] = column
                return .init(capabilityId: "local_data", operation: "csv_group_count", arguments: args)
            }
            if normalized.contains("filter") || normalized.contains("φιλτραρ") {
                guard quoted.count >= 2 else { return nil }
                args["column"] = quoted[0]
                args["value"] = quoted[1]
                if normalized.contains("contains") || normalized.contains("περιεχει") || normalized.contains("περιέχει") { args["mode"] = "contains" }
                return .init(capabilityId: "local_data", operation: "csv_filter", arguments: args)
            }
            if normalized.contains("select columns") || normalized.contains("keep columns") || normalized.contains("στηλες") || normalized.contains("στήλες") {
                guard !quoted.isEmpty else { return nil }
                args["columns"] = quoted.joined(separator: "|")
                return .init(capabilityId: "local_data", operation: "csv_select", arguments: args)
            }
            if normalized.contains("csv to json") || normalized.contains("csv σε json") {
                return .init(capabilityId: "local_data", operation: "csv_to_json", arguments: args)
            }
        }

        if ext == "json" {
            if normalized.contains("pretty json") || normalized.contains("format json") || normalized.contains("μορφοποι") {
                return .init(capabilityId: "local_data", operation: "json_pretty", arguments: args)
            }
            if normalized.contains("json keys") || normalized.contains("κλειδια") || normalized.contains("κλειδιά") {
                return .init(capabilityId: "local_data", operation: "json_keys", arguments: args)
            }
            if normalized.contains("json get") || normalized.contains("json value") || normalized.contains("τιμη") || normalized.contains("τιμή") {
                guard let keyPath = quoted.first, !keyPath.isEmpty else { return nil }
                args["key_path"] = keyPath
                return .init(capabilityId: "local_data", operation: "json_get", arguments: args)
            }
            if normalized.contains("json to csv") || normalized.contains("json σε csv") {
                return .init(capabilityId: "local_data", operation: "json_to_csv", arguments: args)
            }
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

    private func quotedValues(in text: String) -> [String] {
        let pattern = #"[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
