import Foundation

/// Resolves placeholders in deterministic invocation arguments from verified
/// outputs of completed dependency steps.
///
/// Placeholder syntax:
///   {{dep:<step-order>:<key>}}
/// Example:
///   {{dep:1:names}}
///
/// Only completed dependency steps are eligible. Missing or malformed values
/// cause resolution to fail rather than silently guessing.
enum StructuredWorkflowBindingResolver {
    enum ResolutionError: LocalizedError {
        case taskNotFound
        case dependencyNotFound(Int)
        case dependencyNotCompleted(Int)
        case dependencyHasNoStructuredOutput(Int)
        case missingOutputKey(step: Int, key: String)

        var errorDescription: String? {
            switch self {
            case .taskNotFound: return "Το autonomous task δεν βρέθηκε για structured binding resolution."
            case .dependencyNotFound(let order): return "Δεν βρέθηκε dependency step #\(order)."
            case .dependencyNotCompleted(let order): return "Το dependency step #\(order) δεν έχει ολοκληρωθεί ακόμη."
            case .dependencyHasNoStructuredOutput(let order): return "Το dependency step #\(order) δεν επέστρεψε structured output."
            case .missingOutputKey(let step, let key): return "Το dependency step #\(step) δεν επέστρεψε το απαιτούμενο πεδίο '\(key)'."
            }
        }
    }

    static func resolve(
        invocation: DeterministicCapabilityInvocation,
        taskId: UUID?,
        store: AgentTaskStore = .shared
    ) throws -> DeterministicCapabilityInvocation {
        guard invocation.arguments.values.contains(where: { $0.contains("{{dep:") }) else {
            return invocation
        }
        guard let taskId,
              let task = try store.load().first(where: { $0.id == taskId }) else {
            throw ResolutionError.taskNotFound
        }

        var resolved = invocation
        for (key, value) in invocation.arguments {
            resolved.arguments[key] = try resolveValue(value, task: task)
        }
        return resolved
    }

    private static func resolveValue(_ value: String, task: AgentTask) throws -> String {
        let pattern = #"\{\{dep:(\d+):([A-Za-z0-9_\-]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 3,
                  let orderRange = Range(match.range(at: 1), in: value),
                  let keyRange = Range(match.range(at: 2), in: value),
                  let wholeRange = Range(match.range(at: 0), in: result),
                  let order = Int(value[orderRange]) else { continue }

            let outputKey = String(value[keyRange])
            guard let dependency = task.plan.steps.first(where: { $0.order == order }) else {
                throw ResolutionError.dependencyNotFound(order)
            }
            guard dependency.status == .completed else {
                throw ResolutionError.dependencyNotCompleted(order)
            }
            guard let summary = dependency.resultSummary,
                  let values = StructuredStepOutputCodec.values(from: summary) else {
                throw ResolutionError.dependencyHasNoStructuredOutput(order)
            }
            guard let replacement = values[outputKey] else {
                throw ResolutionError.missingOutputKey(step: order, key: outputKey)
            }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }
}
