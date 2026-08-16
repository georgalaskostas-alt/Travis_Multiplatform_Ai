import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService
    private let sessionRecallService: SessionRecallService
    private let taskStore: AgentTaskStore
    var onAssistantMessage: ((String) -> Void)?
    /// Fired instead of normal routing when the message is recognized as a
    /// "bring back an old conversation" request and a match was found.
    var onSessionRecall: ((UUID) -> Void)?

    init(
        approvalGate: ApprovalGateService,
        sessionRecallService: SessionRecallService? = nil,
        taskStore: AgentTaskStore = .shared
    ) {
        self.approvalGate = approvalGate
        self.sessionRecallService = sessionRecallService ?? SessionRecallService()
        self.taskStore = taskStore

        // Repository/source analysis is a core read-only capability of the
        // orchestrator. Register it before AppState adds the generic text
        // capability so source-grounded work cannot silently fall back to
        // ungrounded conversational reasoning.
        let repositoryContext = RepositoryContextCapability()
        capabilities.append(repositoryContext)
        approvalGate.register(capability: repositoryContext)
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability: capability)
    }

    /// `liveSessionId` is the session new messages are actually being
    /// appended to right now — passed in so a recall request never matches
    /// (or needs to search within) the very session it was typed into.
    /// `recentHistory` is a short recent window of the live session's
    /// messages (not including `message` itself) — passed straight through
    /// to whichever capability ends up handling this, so references like
    /// "αυτό"/"σχετικά" resolve against what was actually just said.
    func route(_ message: String, liveSessionId: UUID, recentHistory: [ChatMessage]) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // Runtime diagnostics are deterministic local reads of the same
        // durable snapshot used for crash/relaunch recovery. They bypass AI
        // routing so status/log output cannot hallucinate runtime state.
        if lowered == "/task-status" {
            onAssistantMessage?(renderLatestTaskStatus())
            return
        }

        if lowered == "/task-log" {
            onAssistantMessage?(renderLatestTaskLog())
            return
        }

        if let outcome = try? await sessionRecallService.evaluate(message, excluding: liveSessionId, recentHistory: recentHistory) {
            switch outcome {
            case .found(let sessionId):
                onSessionRecall?(sessionId)
                return
            case .notFound:
                onAssistantMessage?("Δεν βρήκα παλαιότερη συνομιλία που να ταιριάζει με αυτό που ζήτησες.")
                return
            case .notRecall:
                break
            }
        }

        let keywordMatch = capabilities.first(where: { capability in
            !capability.keywords.isEmpty && capability.keywords.contains { lowered.contains($0.lowercased()) }
        })
        let defaultCapability = capabilities.first(where: { $0.keywords.isEmpty })

        guard let capability = keywordMatch ?? defaultCapability else {
            onAssistantMessage?("Δεν κατάλαβα ποια δραστηριότητα αφορά αυτό.")
            return
        }

        do {
            switch try await capability.handle(command: message, recentHistory: recentHistory) {
            case .reply(let text):
                onAssistantMessage?(text)
            case .proposal(let action):
                approvalGate.submit(action)
            case .none:
                break
            }
        } catch {
            onAssistantMessage?("Σφάλμα: \(error.localizedDescription)")
        }
    }

    private func latestPersistedTask() throws -> AgentTask? {
        try taskStore.load().max { lhs, rhs in
            lhs.updatedAt < rhs.updatedAt
        }
    }

    private func renderLatestTaskStatus() -> String {
        do {
            guard let task = try latestPersistedTask() else {
                return "Δεν υπάρχει αποθηκευμένο autonomous task."
            }

            let totalSteps = task.plan.steps.count
            let completedSteps = task.plan.steps.filter {
                $0.status == .completed || $0.status == .skipped
            }.count
            let progress = totalSteps > 0
                ? Int((Double(completedSteps) / Double(totalSteps)) * 100)
                : 0

            let currentStep = task.executionState.currentStepId.flatMap { currentId in
                task.plan.steps.first { $0.id == currentId }
            }

            let completedIds = Set(task.plan.steps.filter { $0.status == .completed }.map(\.id))
            let nextStep = task.plan.steps
                .sorted { $0.order < $1.order }
                .first { step in
                    guard step.status == .pending || step.status == .ready else { return false }
                    return step.dependencyStepIds.allSatisfy { completedIds.contains($0) }
                }

            let activeStepText: String
            if let currentStep {
                activeStepText = "#\(currentStep.order) — \(currentStep.title) [\(currentStep.status.rawValue)]"
            } else if let nextStep {
                activeStepText = "#\(nextStep.order) — \(nextStep.title) [\(nextStep.status.rawValue)]"
            } else {
                activeStepText = "κανένα"
            }

            let checkpoint = task.executionState.lastCheckpoint?.summary ?? "κανένα"
            let failure = task.failureReason ?? "κανένα"
            let runtimeBudget = task.budget.maxRuntimeSeconds.map { "\(Int($0))s" } ?? "unlimited"
            let stepBudget = task.budget.maxSteps.map(String.init) ?? "unlimited"
            let attempts = task.plan.steps.reduce(0) { $0 + $1.attemptCount }

            return """
            AUTONOMOUS TASK STATUS

            TASK
            \(task.id.uuidString)

            TITLE
            \(task.title)

            STATUS
            \(task.status.rawValue)

            PLAN VERSION
            v\(task.plan.version)

            PROGRESS
            \(progress)% (\(completedSteps)/\(totalSteps) steps)

            CURRENT / NEXT STEP
            \(activeStepText)

            TOTAL EXECUTION ATTEMPTS
            \(attempts)

            LAST CHECKPOINT
            \(checkpoint)

            FAILURE / PAUSE DETAIL
            \(failure)

            BUDGET
            maxSteps: \(stepBudget)
            maxRuntime: \(runtimeBudget)
            maxRetriesPerStep: \(task.budget.maxRetriesPerStep)
            """
        } catch {
            return "Αποτυχία ανάγνωσης autonomous task status: \(error.localizedDescription)"
        }
    }

    private func renderLatestTaskLog() -> String {
        do {
            guard let task = try latestPersistedTask() else {
                return "Δεν υπάρχει αποθηκευμένο autonomous task."
            }

            let events = task.events
                .sorted { $0.createdAt < $1.createdAt }
                .suffix(40)

            guard !events.isEmpty else {
                return "Το autonomous task δεν έχει καταγεγραμμένα runtime events."
            }

            let formatter = ISO8601DateFormatter()
            let timeline = events.map { event in
                "[\(formatter.string(from: event.createdAt))] \(event.type.rawValue.uppercased()) — \(event.message)"
            }.joined(separator: "\n")

            return """
            AUTONOMOUS TASK LOG

            TASK
            \(task.id.uuidString)

            STATUS
            \(task.status.rawValue)

            EVENTS
            \(timeline)
            """
        } catch {
            return "Αποτυχία ανάγνωσης autonomous task log: \(error.localizedDescription)"
        }
    }
}
