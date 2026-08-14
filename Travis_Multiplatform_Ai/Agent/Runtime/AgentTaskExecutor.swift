import Foundation
import Observation

enum AgentTaskExecutorError: LocalizedError {
    case taskNotFound
    case taskNotRunning
    case noRunnableStep
    case missingCapability(String)
    case unassignedCapability
    case verificationFailed(String)
    case emptyCapabilityResult

    var errorDescription: String? {
        switch self {
        case .taskNotFound:
            return "Το runtime task δεν βρέθηκε."
        case .taskNotRunning:
            return "Το task δεν βρίσκεται σε running state."
        case .noRunnableStep:
            return "Δεν υπάρχει runnable step αυτή τη στιγμή."
        case .missingCapability(let id):
            return "Δεν βρέθηκε capability με id \(id)."
        case .unassignedCapability:
            return "Το planner δεν ανέθεσε capability σε αυτό το step."
        case .verificationFailed(let reason):
            return "Η επαλήθευση του step απέτυχε: \(reason)"
        case .emptyCapabilityResult:
            return "Το capability δεν επέστρεψε αποτέλεσμα που μπορεί να επαληθευτεί."
        }
    }
}

struct StepVerificationResult: Codable, Hashable {
    let passed: Bool
    let confidence: Double
    let reason: String
    let unmetCriteria: [String]
}

enum AutonomousRunStopReason: String, Codable, Hashable {
    case completed
    case waitingForApproval
    case paused
    case failed
    case noRunnableStep
    case safetyStepLimitReached
}

struct AutonomousRunReport: Codable, Hashable {
    let taskId: UUID
    let stopReason: AutonomousRunStopReason
    let stepsAttempted: Int
    let progress: Double
    let lastCheckpoint: String?
    let nextStepTitle: String?
    let failureReason: String?
    let nextStepAttemptCount: Int?
    let nextStepMaxAttempts: Int?
    let nextStepLastError: String?
}

/// Executes validated AgentTask plan steps through the existing capability
/// system. It never bypasses ApprovalGate and never trusts a capability's
/// result as complete until it is checked against the step's success criteria.
@MainActor
@Observable
final class AgentTaskExecutor {
    private let runtime: AgentTaskRuntime
    private let orchestrator: AgentOrchestrator
    private let approvalGate: ApprovalGateService
    private let verifier: AgentStepVerifier

    private(set) var isExecuting = false
    private(set) var lastExecutionSummary: String?

    var onProgress: ((String) -> Void)?

    init(
        runtime: AgentTaskRuntime,
        orchestrator: AgentOrchestrator,
        approvalGate: ApprovalGateService,
        verifier: AgentStepVerifier = AgentStepVerifier()
    ) {
        self.runtime = runtime
        self.orchestrator = orchestrator
        self.approvalGate = approvalGate
        self.verifier = verifier
    }

    @discardableResult
    func executeNextStep(
        taskId: UUID,
        recentHistory: [ChatMessage] = []
    ) async throws -> PlanStep? {
        guard let task = runtime.task(id: taskId) else {
            throw AgentTaskExecutorError.taskNotFound
        }

        guard task.status == .running else {
            throw AgentTaskExecutorError.taskNotRunning
        }

        guard let step = runtime.nextRunnableStep(taskId: taskId) else {
            throw AgentTaskExecutorError.noRunnableStep
        }

        if step.requiresApproval {
            runtime.markStepWaitingForApproval(taskId: taskId, stepId: step.id)
            let message = "Το step #\(step.order) περιμένει έγκριση: \(step.title)"
            lastExecutionSummary = message
            onProgress?(message)
            return step
        }

        guard let capabilityId = step.capabilityId else {
            runtime.markStepFailed(
                taskId: taskId,
                stepId: step.id,
                error: AgentTaskExecutorError.unassignedCapability.localizedDescription
            )
            throw AgentTaskExecutorError.unassignedCapability
        }

        guard let capability = orchestrator.capabilities.first(where: { $0.id == capabilityId }) else {
            let error = AgentTaskExecutorError.missingCapability(capabilityId)
            runtime.markStepFailed(taskId: taskId, stepId: step.id, error: error.localizedDescription)
            throw error
        }

        isExecuting = true
        defer { isExecuting = false }

        runtime.markStepRunning(taskId: taskId, stepId: step.id)
        runtime.checkpoint(
            taskId: taskId,
            summary: "Executing step #\(step.order): \(step.title)",
            nextAction: "Run capability \(capabilityId)"
        )
        onProgress?("Εκτελώ step #\(step.order): \(step.title)")

        do {
            let outcome = try await capability.handle(
                command: executionCommand(task: task, step: step),
                recentHistory: recentHistory
            )

            switch outcome {
            case .reply(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentTaskExecutorError.emptyCapabilityResult
                }

                let verification = try await verifier.verify(
                    taskGoal: task.goal,
                    step: step,
                    capabilityResult: text
                )

                guard verification.passed else {
                    let reason = verification.reason
                    runtime.markStepFailed(taskId: taskId, stepId: step.id, error: reason)
                    throw AgentTaskExecutorError.verificationFailed(reason)
                }

                runtime.markStepCompleted(
                    taskId: taskId,
                    stepId: step.id,
                    resultSummary: text
                )

                let checkpointSummary =
                    "Step #\(step.order) verified with confidence "
                    + String(format: "%.2f", verification.confidence)

                runtime.checkpoint(
                    taskId: taskId,
                    summary: checkpointSummary,
                    nextAction: runtime.nextRunnableStep(taskId: taskId)?.title
                )

                lastExecutionSummary = checkpointSummary
                onProgress?("""
                ✅ Step #\(step.order) ολοκληρώθηκε και επαληθεύτηκε.
                \(text)
                """)

                return runtime.nextRunnableStep(taskId: taskId)

            case .proposal(let action):
                approvalGate.submit(action)
                runtime.markStepWaitingForApproval(taskId: taskId, stepId: step.id)

                let message = "🔐 Step #\(step.order) δημιούργησε ενέργεια που απαιτεί έγκριση."
                lastExecutionSummary = message
                onProgress?(message)
                return step

            case .none:
                throw AgentTaskExecutorError.emptyCapabilityResult
            }
        } catch {
            // Failed verification may already have transitioned the step back
            // to pending/failed. Only mutate again if it is still running.
            if let latestTask = runtime.task(id: taskId),
               let latestStep = latestTask.plan.steps.first(where: { $0.id == step.id }),
               latestStep.status == .running {
                runtime.markStepFailed(
                    taskId: taskId,
                    stepId: step.id,
                    error: error.localizedDescription
                )
            }

            lastExecutionSummary = error.localizedDescription
            onProgress?("❌ Step #\(step.order) απέτυχε: \(error.localizedDescription)")
            throw error
        }
    }

    /// Runs continuously until a real blocker/terminal state is reached.
    ///
    /// `maxStepsPerCycle` is treated as a minimum requested budget. Runtime
    /// then expands it to cover the plan's legitimate retry envelope
    /// (`plan steps × maxRetriesPerStep`) and applies a hard ceiling of 60
    /// attempts. This prevents ordinary plans from stopping merely because
    /// they contain more than eight steps while still preventing runaway loops.
    func executeUntilBlocked(
        taskId: UUID,
        recentHistory: [ChatMessage] = [],
        maxStepsPerCycle: Int = 8
    ) async throws -> AutonomousRunReport {
        guard let initialTask = runtime.task(id: taskId) else {
            throw AgentTaskExecutorError.taskNotFound
        }

        let retryBudgetPerStep = max(1, initialTask.budget.maxRetriesPerStep)
        let planAttemptBudget = max(1, initialTask.plan.steps.count * retryBudgetPerStep)
        let requestedBudget = max(1, maxStepsPerCycle)
        let safeLimit = min(max(requestedBudget, planAttemptBudget), 60)

        var attempted = 0

        while attempted < safeLimit {
            guard let task = runtime.task(id: taskId) else {
                throw AgentTaskExecutorError.taskNotFound
            }

            switch task.status {
            case .completed:
                return makeRunReport(task: task, reason: .completed, stepsAttempted: attempted)
            case .waitingForApproval:
                return makeRunReport(task: task, reason: .waitingForApproval, stepsAttempted: attempted)
            case .paused:
                return makeRunReport(task: task, reason: .paused, stepsAttempted: attempted)
            case .failed, .cancelled:
                return makeRunReport(task: task, reason: .failed, stepsAttempted: attempted)
            case .pending, .planning, .waitingForDependency:
                return makeRunReport(task: task, reason: .noRunnableStep, stepsAttempted: attempted)
            case .running:
                break
            }

            guard runtime.nextRunnableStep(taskId: taskId) != nil else {
                guard let latest = runtime.task(id: taskId) else {
                    throw AgentTaskExecutorError.taskNotFound
                }
                return makeRunReport(task: latest, reason: .noRunnableStep, stepsAttempted: attempted)
            }

            do {
                _ = try await executeNextStep(taskId: taskId, recentHistory: recentHistory)
                attempted += 1
            } catch {
                attempted += 1

                guard let latest = runtime.task(id: taskId) else {
                    throw AgentTaskExecutorError.taskNotFound
                }

                if latest.status == .running,
                   let retryStep = runtime.nextRunnableStep(taskId: taskId) {
                    let retryMessage = retryStep.lastError.map {
                        "Retrying step #\(retryStep.order) (attempt \(retryStep.attemptCount + 1)/\(retryStep.maxAttempts)): \($0)"
                    } ?? "Retrying step #\(retryStep.order): \(retryStep.title)"
                    onProgress?("↻ \(retryMessage)")
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                if latest.status == .waitingForApproval {
                    return makeRunReport(task: latest, reason: .waitingForApproval, stepsAttempted: attempted)
                }

                if latest.status == .failed || latest.status == .cancelled {
                    return makeRunReport(task: latest, reason: .failed, stepsAttempted: attempted)
                }

                throw error
            }

            await Task.yield()
        }

        guard let latest = runtime.task(id: taskId) else {
            throw AgentTaskExecutorError.taskNotFound
        }

        return makeRunReport(
            task: latest,
            reason: .safetyStepLimitReached,
            stepsAttempted: attempted
        )
    }

    private func makeRunReport(
        task: AgentTask,
        reason: AutonomousRunStopReason,
        stepsAttempted: Int
    ) -> AutonomousRunReport {
        let nextStep = runtime.nextRunnableStep(taskId: task.id)

        return AutonomousRunReport(
            taskId: task.id,
            stopReason: reason,
            stepsAttempted: stepsAttempted,
            progress: runtime.progress(taskId: task.id),
            lastCheckpoint: task.executionState.lastCheckpoint?.summary,
            nextStepTitle: nextStep?.title,
            failureReason: task.failureReason,
            nextStepAttemptCount: nextStep?.attemptCount,
            nextStepMaxAttempts: nextStep?.maxAttempts,
            nextStepLastError: nextStep?.lastError
        )
    }

    private func executionCommand(task: AgentTask, step: PlanStep) -> String {
        let criteria = step.successCriteria
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        Εκτελείς ένα συγκεκριμένο βήμα ενός ήδη εγκεκριμένου execution plan του TRAVIS.

        ΣΥΝΟΛΙΚΟΣ ΣΤΟΧΟΣ:
        \(task.goal)

        ΤΡΕΧΟΝ STEP:
        #\(step.order) — \(step.title)

        ΟΔΗΓΙΕΣ:
        \(step.instructions)

        SUCCESS CRITERIA:
        \(criteria)

        Παρήγαγε το πραγματικό αποτέλεσμα αυτού του step.
        Μην ισχυριστείς ότι έκανες ενέργεια ή έλεγχο που δεν έγινε.
        Μην προχωρήσεις σε επόμενο step.
        Αν το ζητούμενο απαιτεί state-changing action, ακολούθησε το υπάρχον capability approval flow.
        """
    }
}

/// Independent verification pass for an executed step.
final class AgentStepVerifier {
    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func verify(
        taskGoal: String,
        step: PlanStep,
        capabilityResult: String
    ) async throws -> StepVerificationResult {
        let criteria = step.successCriteria
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let prompt = """
        You are the verification component of TRAVIS.

        Evaluate whether the produced result actually satisfies the step.
        Be strict. Do not reward confident wording. Judge only evidence in
        the result. Do not execute tools and do not invent missing evidence.

        TASK GOAL:
        \(taskGoal)

        STEP:
        \(step.title)

        STEP INSTRUCTIONS:
        \(step.instructions)

        SUCCESS CRITERIA:
        \(criteria)

        PRODUCED RESULT:
        \(capabilityResult)

        Return ONLY valid JSON:
        {
          "passed": true,
          "confidence": 0.0,
          "reason": "short reason",
          "unmetCriteria": []
        }

        Rules:
        - confidence must be from 0.0 to 1.0
        - passed may be true only when all essential success criteria are met
        - if evidence is missing, passed must be false
        - unmetCriteria must contain each criterion that was not demonstrated
        """

        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 1200)
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingVerifierJSONFence()

        guard let data = cleaned.data(using: .utf8) else {
            throw AgentTaskExecutorError.verificationFailed(
                "Verifier response was not UTF-8 JSON."
            )
        }

        let result = try JSONDecoder().decode(StepVerificationResult.self, from: data)
        let boundedConfidence = min(max(result.confidence, 0), 1)

        return StepVerificationResult(
            passed: result.passed,
            confidence: boundedConfidence,
            reason: result.reason,
            unmetCriteria: result.unmetCriteria
        )
    }
}

private extension String {
    func removingVerifierJSONFence() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("```json") {
            value.removeFirst("```json".count)
        } else if value.hasPrefix("```") {
            value.removeFirst(3)
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasSuffix("```") {
            value.removeLast(3)
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
