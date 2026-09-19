import Foundation

@MainActor
final class LocalDirectoryArtifactWorkflowIntentRouter {
    static let shared = LocalDirectoryArtifactWorkflowIntentRouter()

    func plan(for goal: String, capabilities: [AgentCapability]) -> TaskPlan? {
        let normalized = goal
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        guard normalized.contains("save") || normalized.contains("write") || normalized.contains("report") || normalized.contains("αποθηκευσ") || normalized.contains("σωσε") || normalized.contains("σώσε") || normalized.contains("αναφορα") || normalized.contains("αναφορά") else { return nil }

        let paths = absolutePaths(in: goal)
        guard paths.count >= 2 else { return nil }
        let source = paths[0]
        let target = URL(fileURLWithPath: paths[1])
        guard !target.lastPathComponent.isEmpty, !target.pathExtension.isEmpty else { return nil }

        let operation: String
        if normalized.contains("duplicate") || normalized.contains("διπλοτυπ") {
            operation = "duplicates"
        } else if normalized.contains("largest files") || normalized.contains("biggest files") || normalized.contains("μεγαλυτερα αρχεια") || normalized.contains("μεγαλύτερα αρχεία") {
            operation = "largest_files"
        } else if normalized.contains("extension summary") || normalized.contains("types of files") || normalized.contains("ανα επεκταση") || normalized.contains("ανά επέκταση") {
            operation = "extension_summary"
        } else if normalized.contains("inventory") || normalized.contains("απογραφ") || normalized.contains("αναλυση φακελου") || normalized.contains("ανάλυση φακέλου") {
            operation = "inventory"
        } else {
            return nil
        }

        var analysisArgs = ["path": source, "recursive": normalized.contains("non recursive") || normalized.contains("μη αναδρομ") ? "false" : "true"]
        if operation == "largest_files", let limit = integer(afterAny: ["top", "limit", "πρωτα", "πρώτα"], in: normalized) {
            analysisArgs["limit"] = String(min(max(limit, 1), 200))
        }

        let specs = [
            LocalWorkflowComposer.StepSpec(
                title: "Analyze the requested folder locally",
                invocation: DeterministicCapabilityInvocation(capabilityId: "local_directory_analysis", operation: operation, arguments: analysisArgs),
                successCriteria: ["Produce the requested folder report locally and expose the exact report as structured output."]
            ),
            LocalWorkflowComposer.StepSpec(
                title: "Save the folder report as \(target.lastPathComponent)",
                invocation: DeterministicCapabilityInvocation(
                    capabilityId: "local_artifact",
                    operation: "write_new",
                    arguments: [
                        "directory": target.deletingLastPathComponent().path,
                        "filename": target.lastPathComponent,
                        "text": "{{dep:1:text}}"
                    ]
                ),
                successCriteria: ["Prepare a new report file containing exactly the verified folder-analysis result, without overwrite."],
                riskLevel: .medium
            )
        ]
        return try? LocalWorkflowComposer.shared.compose(
            summary: "Local folder analysis → saved report workflow (0 planner tokens)",
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

    private func integer(afterAny markers: [String], in text: String) -> Int? {
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let tail = text[range.upperBound...]
            if let token = tail.split(whereSeparator: { !$0.isNumber }).first, let value = Int(token) { return value }
        }
        return nil
    }
}
