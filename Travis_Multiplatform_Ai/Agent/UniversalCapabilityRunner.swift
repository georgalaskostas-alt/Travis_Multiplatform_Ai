import Foundation

/// One execution boundary for every AgentCapability invocation.
/// Centralizes timeout, cancellation propagation, observability and project/task provenance.
@MainActor
final class UniversalCapabilityRunner {
    static let shared = UniversalCapabilityRunner()

    struct Context {
        var taskId: UUID?
        var stepId: UUID?
        var projectId: UUID?
        var recentHistory: [ChatMessage]

        init(taskId: UUID? = nil, stepId: UUID? = nil, projectId: UUID? = nil, recentHistory: [ChatMessage] = []) {
            self.taskId = taskId
            self.stepId = stepId
            self.projectId = projectId
            self.recentHistory = recentHistory
        }
    }

    enum RunnerError: LocalizedError {
        case timedOut(seconds: Int)
        case unsupportedDeterministicInvocation(capabilityId: String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "Το capability ξεπέρασε το execution deadline των \(seconds) δευτερολέπτων."
            case .unsupportedDeterministicInvocation(let capabilityId):
                return "Το capability \(capabilityId) δεν υποστηρίζει structured deterministic execution."
            }
        }
    }

    private let journal: CapabilityExecutionJournal

    init(journal: CapabilityExecutionJournal = .shared) {
        self.journal = journal
    }

    func run(
        capability: AgentCapability,
        command: String,
        context: Context
    ) async throws -> CapabilityOutcome {
        try await runInternal(
            capability: capability,
            commandSummary: command,
            context: context
        ) {
            try await capability.handle(command: command, recentHistory: context.recentHistory)
        }
    }

    /// Zero-parser-token path for capabilities that explicitly opt into a
    /// structured invocation contract. The same timeout, journal, task scope,
    /// policy and downstream approval handling still apply.
    func run(
        capability: AgentCapability,
        invocation: DeterministicCapabilityInvocation,
        context: Context
    ) async throws -> CapabilityOutcome {
        guard invocation.capabilityId == capability.id,
              let deterministic = capability as? any DeterministicInvocableCapability else {
            throw RunnerError.unsupportedDeterministicInvocation(capabilityId: capability.id)
        }

        let argumentSummary = invocation.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let summary = "structured \(invocation.operation) \(argumentSummary)"

        return try await runInternal(
            capability: capability,
            commandSummary: summary,
            context: context
        ) {
            try await deterministic.handle(invocation: invocation)
        }
    }

    private func runInternal(
        capability: AgentCapability,
        commandSummary: String,
        context: Context,
        operation: @escaping @MainActor () async throws -> CapabilityOutcome
    ) async throws -> CapabilityOutcome {
        let descriptor = capability.descriptor
        let timeout = descriptor.policy.timeoutSeconds
        let recordId = journal.begin(
            capabilityId: descriptor.id,
            command: commandSummary,
            taskId: context.taskId,
            projectId: context.projectId
        )
        let aiContext = AIInvocationContext(
            workload: .routine,
            capabilityId: descriptor.id,
            taskId: context.taskId,
            stepId: context.stepId,
            projectId: context.projectId,
            operation: "capability.handle"
        )

        do {
            let outcome = try await withThrowingTaskGroup(of: CapabilityOutcome.self) { group in
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    return try await AIExecutionScope.$context.withValue(aiContext) {
                        try await operation()
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    try Task.checkCancellation()
                    throw RunnerError.timedOut(seconds: timeout)
                }

                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }

            switch outcome {
            case .reply(let text):
                journal.finish(recordId: recordId, status: .replied, resultSummary: text)
                VerifiedRoutingMemory.shared.recordSuccessfulRouting(
                    command: commandSummary,
                    capabilityId: descriptor.id
                )
            case .proposal(let action):
                journal.finish(recordId: recordId, status: .proposedMutation, resultSummary: action.summary)
                VerifiedRoutingMemory.shared.recordSuccessfulRouting(
                    command: commandSummary,
                    capabilityId: descriptor.id
                )
            case .none:
                journal.finish(recordId: recordId, status: .noResult)
            }
            return outcome
        } catch is CancellationError {
            journal.finish(recordId: recordId, status: .cancelled, error: "Execution cancelled")
            throw CancellationError()
        } catch let error as RunnerError {
            journal.finish(recordId: recordId, status: .timedOut, error: error.localizedDescription)
            throw error
        } catch {
            journal.finish(recordId: recordId, status: .failed, error: error.localizedDescription)
            throw error
        }
    }
}
