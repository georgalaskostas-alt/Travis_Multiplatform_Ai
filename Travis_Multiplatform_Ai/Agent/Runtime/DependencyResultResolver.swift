import Foundation

/// Resolves a structured invocation using only verified outputs from completed
/// dependency steps. This lets local workflows pass concrete results forward
/// without asking an AI model to reinterpret them.
enum DependencyResultResolver {
    static func resolve(
        invocation: DeterministicCapabilityInvocation,
        task: AgentTask,
        step: PlanStep
    ) -> DeterministicCapabilityInvocation {
        guard invocation.capabilityId == "advanced_filesystem",
              ["copy", "move", "delete", "organize_extension"].contains(invocation.operation),
              !step.dependencyStepIds.isEmpty else {
            return invocation
        }

        let dependencyIds = Set(step.dependencyStepIds)
        let dependencies = task.plan.steps
            .filter { dependencyIds.contains($0.id) && $0.status == .completed }
            .sorted { $0.order < $1.order }

        var names: [String] = []
        for dependency in dependencies {
            guard dependency.capabilityId == "local_file_search",
                  let result = dependency.resultSummary else { continue }
            names.append(contentsOf: fileNames(fromLocalSearchResult: result))
        }

        let uniqueNames = Array(NSOrderedSet(array: names)).compactMap { $0 as? String }
        guard !uniqueNames.isEmpty else { return invocation }

        var arguments = invocation.arguments
        arguments["names"] = uniqueNames.joined(separator: "|")
        // Once exact verified names are available, remove the broad selector.
        arguments.removeValue(forKey: "matchExtension")

        return DeterministicCapabilityInvocation(
            capabilityId: invocation.capabilityId,
            operation: invocation.operation,
            arguments: arguments
        )
    }

    private static func fileNames(fromLocalSearchResult text: String) -> [String] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.hasPrefix("FILE |") else { return nil }
            let fields = line.components(separatedBy: " | ")
            guard fields.count >= 4 else { return nil }
            let relativePath = fields.dropFirst(3).joined(separator: " | ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty,
                  !relativePath.contains("/"),
                  relativePath != ".",
                  relativePath != ".." else { return nil }
            return relativePath
        }
    }
}
