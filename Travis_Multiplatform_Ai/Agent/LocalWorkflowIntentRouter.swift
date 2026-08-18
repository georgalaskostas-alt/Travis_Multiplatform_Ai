import Foundation

@MainActor
final class LocalWorkflowIntentRouter {
    static let shared = LocalWorkflowIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        let paths = absolutePaths(in: goal)

        if let plan = fileTransferPlan(goal: goal, normalized: normalized, paths: paths, capabilities: capabilities) { return plan }
        if let plan = fileDeletePlan(goal: goal, normalized: normalized, paths: paths, capabilities: capabilities) { return plan }
        if let plan = createFolderPlan(goal: goal, normalized: normalized, paths: paths, capabilities: capabilities) { return plan }
        if let plan = documentNormalizePlan(normalized: normalized, paths: paths, capabilities: capabilities) { return plan }
        if let plan = documentReplacePlan(goal: goal, normalized: normalized, paths: paths, capabilities: capabilities) { return plan }
        return nil
    }

    private func fileTransferPlan(goal: String, normalized: String, paths: [String], capabilities: [AgentCapability]) -> TaskPlan? {
        guard paths.count >= 2 else { return nil }
        let isMove = ["move", "μετακινησ", "μεταφερ"].contains { normalized.contains($0) }
        let isCopy = ["copy", "αντιγρα"].contains { normalized.contains($0) }
        guard isMove != isCopy else { return nil }
        guard let ext = explicitExtension(in: goal) else { return nil }

        let source = paths[0]
        let destination = paths[1]
        let specs = [
            LocalWorkflowComposer.StepSpec(
                title: "Find .\(ext) files locally",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_file_search",
                    operation: "search",
                    arguments: ["path": source, "extension": ext, "recursive": "false", "limit": "1000"]
                ),
                successCriteria: ["Return the matching local files and expose their exact filenames as structured verified output."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "\(isMove ? "Move" : "Copy") the files found in step 1",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "advanced_filesystem",
                    operation: isMove ? "move" : "copy",
                    arguments: [
                        "sourcePath": source,
                        "destinationPath": destination,
                        "names": "{{dep:1:names}}"
                    ]
                ),
                successCriteria: ["Prepare the scoped filesystem operation for exactly the filenames verified by step 1, without collisions."],
                riskLevel: .medium
            )
        ]
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local file search → \(isMove ? "move" : "copy") workflow with verified output chaining (0 planner tokens)",
            steps: specs,
            capabilities: capabilities
        )
    }

    private func fileDeletePlan(goal: String, normalized: String, paths: [String], capabilities: [AgentCapability]) -> TaskPlan? {
        let marker = ["delete files", "delete all", "διαγραψε", "διεγραψε", "διέγραψε"].contains { normalized.contains($0) }
        guard marker, let source = paths.first, let ext = explicitExtension(in: goal) else { return nil }
        let specs = [
            LocalWorkflowComposer.StepSpec(
                title: "Find .\(ext) files before deletion",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_file_search",
                    operation: "search",
                    arguments: ["path": source, "extension": ext, "recursive": "false", "limit": "1000"]
                ),
                successCriteria: ["List the exact matching files and expose their filenames as structured verified output before any deletion is proposed."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "Delete only the files found in step 1",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "advanced_filesystem",
                    operation: "delete",
                    arguments: ["sourcePath": source, "names": "{{dep:1:names}}"]
                ),
                successCriteria: ["Prepare an approval-gated deletion proposal for exactly the filenames verified by step 1."],
                riskLevel: .high
            )
        ]
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local file search → delete workflow with verified output chaining (0 planner tokens)",
            steps: specs,
            capabilities: capabilities
        )
    }

    private func createFolderPlan(goal: String, normalized: String, paths: [String], capabilities: [AgentCapability]) -> TaskPlan? {
        let marker = ["create folder", "new folder", "δημιουργησε φακελο", "φτιαξε φακελο"].contains { normalized.contains($0) }
        guard marker, let parent = paths.first else { return nil }
        let quoted = quotedValues(in: goal)
        guard let name = quoted.first, isSafeSimpleName(name) else { return nil }
        let spec = LocalWorkflowComposer.StepSpec(
            title: "Create folder \(name)",
            invocation: DeterministicCapabilityInvocation(
                capabilityId: "advanced_filesystem",
                operation: "create_folder",
                arguments: ["sourcePath": parent, "folderName": name]
            ),
            successCriteria: ["Prepare an approval-gated folder creation at the exact requested path."],
            riskLevel: .medium
        )
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local create-folder workflow (0 planner tokens)",
            steps: [spec],
            capabilities: capabilities
        )
    }

    private func documentNormalizePlan(normalized: String, paths: [String], capabilities: [AgentCapability]) -> TaskPlan? {
        let marker = normalized.contains("normalize whitespace") || normalized.contains("κανονικοποι") && normalized.contains("κενα")
        guard marker, let source = paths.first else { return nil }
        var args = ["path": source]
        if paths.count >= 2 { args["output_path"] = paths[1] }
        let spec = LocalWorkflowComposer.StepSpec(
            title: "Normalize document whitespace locally",
            invocation: DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_normalized", arguments: args),
            successCriteria: ["Produce a deterministic whitespace-normalized document proposal or report that no change is required."],
            riskLevel: .medium
        )
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local document normalization workflow (0 planner tokens)",
            steps: [spec], capabilities: capabilities
        )
    }

    private func documentReplacePlan(goal: String, normalized: String, paths: [String], capabilities: [AgentCapability]) -> TaskPlan? {
        guard normalized.contains("replace") || normalized.contains("αντικαταστ") else { return nil }
        guard let source = paths.first else { return nil }
        let quoted = quotedValues(in: goal)
        guard quoted.count >= 2, !quoted[0].isEmpty else { return nil }
        var args = ["path": source, "find": quoted[0], "replace": quoted[1]]
        if paths.count >= 2 { args["output_path"] = paths[1] }
        let spec = LocalWorkflowComposer.StepSpec(
            title: "Replace exact text in document locally",
            invocation: DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_replace", arguments: args),
            successCriteria: ["Prepare the exact text replacement as a scoped document mutation proposal."],
            riskLevel: .medium
        )
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local exact-text replacement workflow (0 planner tokens)",
            steps: [spec], capabilities: capabilities
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
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}
