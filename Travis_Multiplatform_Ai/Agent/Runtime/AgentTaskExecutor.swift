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

enum StepVerificationVerdict: String, Codable, Hashable {
    case pass
    case retry
    case insufficientEvidence = "insufficient_evidence"
}

struct StepVerificationResult: Codable, Hashable {
    let verdict: StepVerificationVerdict
    let confidence: Double
    let reason: String
    let unmetCriteria: [String]

    var passed: Bool { verdict == .pass }
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

@MainActor
@Observable
final class AgentTaskExecutor {
    static let runtimeFingerprint = "runtime-v1.7-scope-aware"

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
        guard let task = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
        guard task.status == .running else { throw AgentTaskExecutorError.taskNotRunning }
        guard let step = runtime.nextRunnableStep(taskId: taskId) else { throw AgentTaskExecutorError.noRunnableStep }

        if step.requiresApproval {
            runtime.markStepWaitingForApproval(taskId: taskId, stepId: step.id)
            let message = "Το step #\(step.order) περιμένει έγκριση: \(step.title)"
            lastExecutionSummary = message
            onProgress?(message)
            return step
        }

        guard let capabilityId = step.capabilityId else {
            runtime.markStepFailed(taskId: taskId, stepId: step.id, error: AgentTaskExecutorError.unassignedCapability.localizedDescription)
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

        let trace = "[TRAVIS \(Self.runtimeFingerprint) | capability=\(capabilityId) | step=\(step.order)]"
        onProgress?("\(trace)\nΕκτελώ step #\(step.order): \(step.title)")

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

                switch verification.verdict {
                case .pass:
                    runtime.markStepCompleted(taskId: taskId, stepId: step.id, resultSummary: text)

                    let checkpointSummary = "Step #\(step.order) verified with confidence " + String(format: "%.2f", verification.confidence)
                    runtime.checkpoint(
                        taskId: taskId,
                        summary: checkpointSummary,
                        nextAction: runtime.nextRunnableStep(taskId: taskId)?.title
                    )

                    lastExecutionSummary = checkpointSummary
                    onProgress?("""
                    \(trace)
                    ✅ Step #\(step.order) ολοκληρώθηκε και επαληθεύτηκε.
                    \(text)
                    """)
                    return runtime.nextRunnableStep(taskId: taskId)

                case .insufficientEvidence:
                    // Repository inspection is allowed to complete with an explicit,
                    // verified limitation. This preserves honest evidence boundaries
                    // and allows downstream synthesis to reason over the limitation
                    // instead of killing the whole autonomous task.
                    if capabilityId == "repository_context" {
                        let limitedResult = """
                        \(text)

                        VERIFICATION LIMITATION
                        \(verification.reason)
                        Unmet scope: \(verification.unmetCriteria.joined(separator: " | "))
                        """

                        runtime.markStepCompleted(
                            taskId: taskId,
                            stepId: step.id,
                            resultSummary: limitedResult
                        )

                        let checkpointSummary = "Step #\(step.order) completed with verified evidence limitation"
                        runtime.checkpoint(
                            taskId: taskId,
                            summary: checkpointSummary,
                            nextAction: runtime.nextRunnableStep(taskId: taskId)?.title
                        )

                        lastExecutionSummary = checkpointSummary
                        onProgress?("""
                        \(trace)
                        ⚠️ Step #\(step.order) ολοκληρώθηκε με περιορισμό evidence — το task συνεχίζει.
                        \(limitedResult)
                        """)
                        return runtime.nextRunnableStep(taskId: taskId)
                    }

                    let reason = verification.reason
                    runtime.markStepFailed(taskId: taskId, stepId: step.id, error: reason)
                    throw AgentTaskExecutorError.verificationFailed(reason)

                case .retry:
                    let reason = verification.reason
                    runtime.markStepFailed(taskId: taskId, stepId: step.id, error: reason)
                    throw AgentTaskExecutorError.verificationFailed(reason)
                }

            case .proposal(let action):
                approvalGate.submit(action)
                runtime.markStepWaitingForApproval(taskId: taskId, stepId: step.id)
                let message = "\(trace)\n🔐 Step #\(step.order) δημιούργησε ενέργεια που απαιτεί έγκριση."
                lastExecutionSummary = message
                onProgress?(message)
                return step

            case .none:
                throw AgentTaskExecutorError.emptyCapabilityResult
            }
        } catch {
            if let latestTask = runtime.task(id: taskId),
               let latestStep = latestTask.plan.steps.first(where: { $0.id == step.id }),
               latestStep.status == .running {
                runtime.markStepFailed(taskId: taskId, stepId: step.id, error: error.localizedDescription)
            }

            lastExecutionSummary = error.localizedDescription
            onProgress?("\(trace)\n❌ Step #\(step.order) απέτυχε: \(error.localizedDescription)")
            throw error
        }
    }

    func executeUntilBlocked(
        taskId: UUID,
        recentHistory: [ChatMessage] = [],
        maxStepsPerCycle: Int = 8
    ) async throws -> AutonomousRunReport {
        guard let initialTask = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }

        let retryBudgetPerStep = max(1, initialTask.budget.maxRetriesPerStep)
        let planAttemptBudget = max(1, initialTask.plan.steps.count * retryBudgetPerStep)
        let requestedBudget = max(1, maxStepsPerCycle)
        let safeLimit = min(max(requestedBudget, planAttemptBudget), 60)

        var attempted = 0

        while attempted < safeLimit {
            guard let task = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }

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
                guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
                return makeRunReport(task: latest, reason: .noRunnableStep, stepsAttempted: attempted)
            }

            do {
                _ = try await executeNextStep(taskId: taskId, recentHistory: recentHistory)
                attempted += 1
            } catch {
                attempted += 1

                guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }

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

        guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
        return makeRunReport(task: latest, reason: .safetyStepLimitReached, stepsAttempted: attempted)
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
        let criteria = step.successCriteria.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let dependencyEvidence = dependencyEvidenceBlock(task: task, step: step)

        return """
        RUNTIME FINGERPRINT:
        \(Self.runtimeFingerprint)

        Εκτελείς ένα συγκεκριμένο βήμα ενός ήδη εγκεκριμένου execution plan του TRAVIS.

        ΣΥΝΟΛΙΚΟΣ ΣΤΟΧΟΣ (context only — do not expand this step's scope to the whole goal):
        \(task.goal)

        ΤΡΕΧΟΝ STEP:
        #\(step.order) — \(step.title)

        ΟΔΗΓΙΕΣ:
        \(step.instructions)

        VERIFIED DEPENDENCY EVIDENCE:
        \(dependencyEvidence)

        SUCCESS CRITERIA FOR THIS STEP ONLY:
        \(criteria)

        Παρήγαγε το πραγματικό αποτέλεσμα μόνο αυτού του step.
        Χρησιμοποίησε τα VERIFIED DEPENDENCY EVIDENCE ως canonical outputs προηγούμενων βημάτων.
        Μην παρουσιάσεις ως verified κάτι που δεν υπάρχει στα dependency outputs ή στο capability evidence που φορτώνεται τώρα.
        Αν το loaded evidence δεν καλύπτει κάτι έξω από το scope αυτού του step, κατέγραψέ το ως limitation — μην προσπαθήσεις να αποδείξεις ολόκληρο το repository.
        Μην προχωρήσεις σε επόμενο step.
        """
    }

    private func dependencyEvidenceBlock(task: AgentTask, step: PlanStep) -> String {
        guard !step.dependencyStepIds.isEmpty else { return "None — this step has no dependencies." }

        let dependencyIds = Set(step.dependencyStepIds)
        let dependencies = task.plan.steps
            .filter { dependencyIds.contains($0.id) }
            .sorted { $0.order < $1.order }

        var sections: [String] = []
        var totalCharacters = 0
        let maxTotalCharacters = 80_000
        let maxCharactersPerDependency = 14_000

        for dependency in dependencies {
            guard totalCharacters < maxTotalCharacters else { break }

            guard dependency.status == .completed,
                  let result = dependency.resultSummary,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                sections.append("--- DEPENDENCY STEP #\(dependency.order): \(dependency.title) ---\nNo verified result is available.")
                continue
            }

            let remaining = maxTotalCharacters - totalCharacters
            let allowed = min(maxCharactersPerDependency, remaining)
            let clipped = String(result.prefix(allowed))
            let truncation = result.count > clipped.count ? "\n[DEPENDENCY RESULT TRUNCATED BY EXECUTION CONTEXT BUDGET]" : ""

            sections.append("--- DEPENDENCY STEP #\(dependency.order): \(dependency.title) ---\n\(clipped)\(truncation)")
            totalCharacters += clipped.count
        }

        return sections.isEmpty ? "No completed dependency evidence is available." : sections.joined(separator: "\n\n")
    }
}

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
        let criteria = step.successCriteria.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
        You are the scope-aware verification component of TRAVIS.

        Verify ONLY the current step. The overall task goal is context, not an
        instruction to demand repository-wide completeness from this step.
        Judge only evidence in the produced result. Do not invent missing evidence.

        OVERALL TASK GOAL (context only):
        \(taskGoal)

        CURRENT STEP:
        \(step.title)

        STEP INSTRUCTIONS:
        \(step.instructions)

        SUCCESS CRITERIA FOR THIS STEP ONLY:
        \(criteria)

        PRODUCED RESULT:
        \(capabilityResult)

        Return ONLY valid JSON:
        {
          "verdict": "pass|retry|insufficient_evidence",
          "confidence": 0.0,
          "reason": "short reason",
          "unmetCriteria": []
        }

        Verdict rules:
        - pass: the current step's scoped criteria are demonstrated.
        - retry: evidence was available but the result is materially wrong, contradictory, malformed, or failed to use it.
        - insufficient_evidence: the result is honest and grounded, but the loaded evidence cannot establish part of the requested scope.
        - A stated limitation about OUT-OF-SCOPE repository areas is NOT a failure when the current step's own scope is satisfied.
        - Do not require tests, docs, generated artifacts, unrelated subsystems, or repository-wide classification unless the step title/instructions explicitly request them.
        - For repository inspection, source-level evidence for the named subsystem is enough; absence of unrelated evidence must not trigger retry.
        - confidence must be 0.0...1.0.
        - unmetCriteria lists only current-step criteria not demonstrated.
        """

        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 1200)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).removingVerifierJSONFence()

        guard let data = cleaned.data(using: .utf8) else {
            throw AgentTaskExecutorError.verificationFailed("Verifier response was not UTF-8 JSON.")
        }

        let result = try JSONDecoder().decode(StepVerificationResult.self, from: data)
        return StepVerificationResult(
            verdict: result.verdict,
            confidence: min(max(result.confidence, 0), 1),
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
        if value.hasSuffix("```") { value.removeLast(3) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
