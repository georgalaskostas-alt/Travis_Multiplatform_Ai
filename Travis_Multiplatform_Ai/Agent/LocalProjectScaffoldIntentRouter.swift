import Foundation

@MainActor
final class LocalProjectScaffoldIntentRouter {
    static let shared = LocalProjectScaffoldIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()

        let wantsProject = normalized.contains("project") || normalized.contains("workspace") || normalized.contains("εργασιας")
        let wantsCreate = normalized.contains("create") || normalized.contains("make") || normalized.contains("φτιαξε") || normalized.contains("δημιουργησε")
        guard wantsProject && wantsCreate else { return nil }

        let paths = absolutePaths(in: goal)
        guard let parentPath = paths.first else { return nil }
        let quoted = quotedValues(in: goal)
        guard let projectName = quoted.first, isSafeSimpleName(projectName) else { return nil }

        let requestedFolders = folderList(in: goal)
        var arguments = [
            "parentPath": parentPath,
            "projectName": projectName
        ]
        if !requestedFolders.isEmpty {
            arguments["folders"] = requestedFolders.joined(separator: "|")
        }

        let spec = LocalWorkflowComposer.StepSpec(
            title: "Create project workspace \(projectName)",
            invocation: DeterministicCapabilityInvocation(
                capabilityId: "local_project_scaffold",
                operation: "create_scaffold",
                arguments: arguments
            ),
            successCriteria: ["Prepare one approval-gated creation of a new project folder, starter subfolders and README without overwriting anything."],
            riskLevel: .medium
        )

        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local project workspace scaffold (0 planner tokens)",
            steps: [spec],
            capabilities: capabilities
        )
    }

    private func folderList(in text: String) -> [String] {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        guard normalized.contains("folders") || normalized.contains("subfolders") || normalized.contains("φακελους") else { return [] }

        let quoted = quotedValues(in: text)
        guard quoted.count > 1 else { return [] }
        return Array(quoted.dropFirst()).filter(isSafeSimpleName).prefix(20).map { $0 }
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

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("|")
    }
}
