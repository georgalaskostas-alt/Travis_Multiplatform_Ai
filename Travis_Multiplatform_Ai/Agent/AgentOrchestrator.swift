import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities: [AgentCapability] = []
    let approvalGate: ApprovalGateService
    private let sessionRecallService: SessionRecallService
    private let taskStore: AgentTaskStore
    private let capabilityRunner: UniversalCapabilityRunner
    var onAssistantMessage: ((String) -> Void)?
    /// Fired instead of normal routing when the message is recognized as a
    /// "bring back an old conversation" request and a match was found.
    var onSessionRecall: ((UUID) -> Void)?

    init(
        approvalGate: ApprovalGateService,
        sessionRecallService: SessionRecallService? = nil,
        taskStore: AgentTaskStore = .shared,
        capabilityRunner: UniversalCapabilityRunner = .shared
    ) {
        self.approvalGate = approvalGate
        self.sessionRecallService = sessionRecallService ?? SessionRecallService()
        self.taskStore = taskStore
        self.capabilityRunner = capabilityRunner

        let repositoryContext = RepositoryContextCapability()
        capabilities.append(repositoryContext)
        approvalGate.register(capability: repositoryContext)
    }

    func register(_ capability: AgentCapability) {
        capabilities.append(capability)
        approvalGate.register(capability: capability)
    }

    func route(_ message: String, liveSessionId: UUID, recentHistory: [ChatMessage]) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered == "/tasks" {
            onAssistantMessage?(renderTaskHistory())
            return
        }
        if lowered == "/task-status" {
            onAssistantMessage?(renderTaskStatus(reference: nil))
            return
        }
        if lowered.hasPrefix("/task-status ") {
            let reference = String(trimmed.dropFirst("/task-status ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            onAssistantMessage?(renderTaskStatus(reference: reference))
            return
        }
        if lowered == "/task-log" {
            onAssistantMessage?(renderTaskLog(reference: nil))
            return
        }
        if lowered.hasPrefix("/task-log ") {
            let reference = String(trimmed.dropFirst("/task-log ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            onAssistantMessage?(renderTaskLog(reference: reference))
            return
        }
        if lowered == "/capability-log" {
            onAssistantMessage?(CapabilityExecutionJournal.shared.diagnosticReport())
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
            let outcome = try await capabilityRunner.run(
                capability: capability,
                command: message,
                context: .init(recentHistory: recentHistory)
            )
            switch outcome {
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

    private enum TaskResolution {
        case found(AgentTask)
        case ambiguous([AgentTask])
        case notFound
    }

    private func persistedTasksNewestFirst() throws -> [AgentTask] {
        try taskStore.load().sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
    }

    private func resolveTask(reference: String?) throws -> TaskResolution {
        let tasks = try persistedTasksNewestFirst()
        guard !tasks.isEmpty else { return .notFound }
        guard let rawReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !rawReference.isEmpty else {
            return .found(tasks[0])
        }
        let reference = rawReference.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
        if let exact = tasks.first(where: { $0.id.uuidString.lowercased() == reference }) { return .found(exact) }
        let uuidPrefixMatches = tasks.filter { $0.id.uuidString.lowercased().hasPrefix(reference) }
        if uuidPrefixMatches.count == 1 { return .found(uuidPrefixMatches[0]) }
        if uuidPrefixMatches.count > 1 { return .ambiguous(uuidPrefixMatches) }

        let normalizedStatus: AgentTaskStatus? = {
            let aliases: [String: AgentTaskStatus] = [
                "failed": .failed, "αποτυχημενο": .failed, "αποτυχια": .failed,
                "completed": .completed, "ολοκληρωμενο": .completed,
                "running": .running, "ενεργο": .running, "τρεχει": .running,
                "paused": .paused, "παγωμενο": .paused, "σε παυση": .paused,
                "cancelled": .cancelled, "ακυρωμενο": .cancelled,
                "waitingforapproval": .waitingForApproval, "approval": .waitingForApproval
            ]
            if let direct = AgentTaskStatus(rawValue: reference) { return direct }
            return aliases[reference]
        }()
        if let normalizedStatus, let first = tasks.first(where: { $0.status == normalizedStatus }) { return .found(first) }

        let stopWords: Set<String> = ["task", "το", "του", "τη", "την", "για", "με", "μου", "ένα", "ενα", "status", "log", "δειξε", "δείξε", "show", "previous", "προηγουμενο", "τελευταιο", "latest"]
        let queryTokens = reference.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }
        guard !queryTokens.isEmpty else { return .notFound }
        let scored = tasks.compactMap { task -> (AgentTask, Int)? in
            let searchable = (task.title + " " + task.goal).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR")).lowercased()
            let score = queryTokens.reduce(0) { $0 + (searchable.contains($1) ? 1 : 0) }
            return score > 0 ? (task, score) : nil
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
        guard let best = scored.first else { return .notFound }
        if scored.count > 1, scored[1].1 == best.1 { return .ambiguous(scored.filter { $0.1 == best.1 }.map(\.0)) }
        return .found(best.0)
    }

    private func renderTaskHistory() -> String {
        do {
            let tasks = try persistedTasksNewestFirst()
            guard !tasks.isEmpty else { return "Δεν υπάρχει αποθηκευμένο autonomous task." }
            let rows = tasks.prefix(20).map { task in
                let total = task.plan.steps.count
                let completed = task.plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
                let progress = total > 0 ? Int((Double(completed) / Double(total)) * 100) : 0
                return "\(task.id.uuidString.prefix(8))  [\(task.status.rawValue)]  \(progress)%  v\(task.plan.version)  — \(task.title)"
            }.joined(separator: "\n")
            return "AUTONOMOUS TASK HISTORY\n\n\(rows)\n\nΧρήση:\n/task-status <ID ή λέξη από τίτλο>\n/task-log <ID ή λέξη από τίτλο>"
        } catch { return "Αποτυχία ανάγνωσης autonomous task history: \(error.localizedDescription)" }
    }

    private func renderTaskStatus(reference: String?) -> String {
        do {
            switch try resolveTask(reference: reference) {
            case .notFound: return "Δεν βρέθηκε autonomous task που να ταιριάζει με \(reference ?? "την επιλογή"). Χρησιμοποίησε /tasks για τη λίστα."
            case .ambiguous(let tasks): return renderAmbiguousTaskSelection(tasks, command: "/task-status")
            case .found(let task): return renderStatus(for: task)
            }
        } catch { return "Αποτυχία ανάγνωσης autonomous task status: \(error.localizedDescription)" }
    }

    private func renderStatus(for task: AgentTask) -> String {
        let totalSteps = task.plan.steps.count
        let completedSteps = task.plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
        let progress = totalSteps > 0 ? Int((Double(completedSteps) / Double(totalSteps)) * 100) : 0
        let currentStep = task.executionState.currentStepId.flatMap { currentId in task.plan.steps.first { $0.id == currentId } }
        let completedIds = Set(task.plan.steps.filter { $0.status == .completed }.map(\.id))
        let nextStep = task.plan.steps.sorted { $0.order < $1.order }.first { step in
            guard step.status == .pending || step.status == .ready else { return false }
            return step.dependencyStepIds.allSatisfy { completedIds.contains($0) }
        }
        let activeStepText: String
        if let currentStep { activeStepText = "#\(currentStep.order) — \(currentStep.title) [\(currentStep.status.rawValue)]" }
        else if let nextStep { activeStepText = "#\(nextStep.order) — \(nextStep.title) [\(nextStep.status.rawValue)]" }
        else { activeStepText = "κανένα" }
        return "AUTONOMOUS TASK STATUS\n\nTASK\n\(task.id.uuidString)\n\nTITLE\n\(task.title)\n\nSTATUS\n\(task.status.rawValue)\n\nPLAN VERSION\nv\(task.plan.version)\n\nPROGRESS\n\(progress)% (\(completedSteps)/\(totalSteps) steps)\n\nCURRENT / NEXT STEP\n\(activeStepText)\n\nTOTAL EXECUTION ATTEMPTS\n\(task.executionState.totalExecutionAttempts)\n\nLAST CHECKPOINT\n\(task.executionState.lastCheckpoint?.summary ?? "κανένα")\n\nFAILURE / PAUSE DETAIL\n\(task.failureReason ?? task.pauseReason ?? "κανένα")\n\nBUDGET\nmaxSteps: \(task.executionBudget.maxTotalStepExecutions)\nmaxRuntime: \(task.executionBudget.maxRuntimeSeconds.map(String.init) ?? "unlimited")\nmaxRetriesPerStep: \(task.executionBudget.maxRetriesPerStep)"
    }

    private func renderTaskLog(reference: String?) -> String {
        do {
            switch try resolveTask(reference: reference) {
            case .notFound: return "Δεν βρέθηκε autonomous task. Χρησιμοποίησε /tasks."
            case .ambiguous(let tasks): return renderAmbiguousTaskSelection(tasks, command: "/task-log")
            case .found(let task):
                let formatter = ISO8601DateFormatter()
                let events = task.executionState.events.map { "[\(formatter.string(from: $0.timestamp))] \($0.kind.rawValue.uppercased()) — \($0.message)" }.joined(separator: "\n")
                return "AUTONOMOUS TASK LOG\n\nTASK\n\(task.id.uuidString)\n\nSTATUS\n\(task.status.rawValue)\n\nEVENTS\n\(events.isEmpty ? "κανένα" : events)"
            }
        } catch { return "Αποτυχία ανάγνωσης autonomous task log: \(error.localizedDescription)" }
    }

    private func renderAmbiguousTaskSelection(_ tasks: [AgentTask], command: String) -> String {
        let rows = tasks.prefix(10).map { "\($0.id.uuidString.prefix(8)) [\($0.status.rawValue)] — \($0.title)" }.joined(separator: "\n")
        return "Βρήκα περισσότερα από ένα tasks:\n\n\(rows)\n\nΧρησιμοποίησε \(command) <short ID>."
    }
}
