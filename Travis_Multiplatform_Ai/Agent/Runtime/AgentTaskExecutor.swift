import Foundation
import Observation

enum AgentTaskExecutorError: LocalizedError {
    case taskNotFound
    case taskNotRunning
    case noRunnableStep
    case taskAlreadyExecuting(UUID)
    case missingCapability(String)
    case unassignedCapability
    case verificationFailed(String)
    case emptyCapabilityResult
    case capabilityTimedOut(seconds: Int)
    case taskBudgetExceeded(String)

    var errorDescription: String? {
        switch self {
        case .taskNotFound: return "Το runtime task δεν βρέθηκε."
        case .taskNotRunning: return "Το task δεν βρίσκεται σε running state."
        case .noRunnableStep: return "Δεν υπάρχει runnable step αυτή τη στιγμή."
        case .taskAlreadyExecuting(let taskId):
            return "Το autonomous task \(taskId.uuidString) εκτελείται ήδη. Περίμενε να ολοκληρωθεί ο τρέχων execution cycle."
        case .missingCapability(let id): return "Δεν βρέθηκε capability με id \(id)."
        case .unassignedCapability: return "Το planner δεν ανέθεσε capability σε αυτό το step."
        case .verificationFailed(let reason): return "Η επαλήθευση του step απέτυχε: \(reason)"
        case .emptyCapabilityResult: return "Το capability δεν επέστρεψε αποτέλεσμα που μπορεί να επαληθευτεί."
        case .capabilityTimedOut(let seconds): return "Το capability ξεπέρασε το execution deadline των \(seconds) δευτερολέπτων."
        case .taskBudgetExceeded(let reason): return "Το autonomous task σταμάτησε επειδή εξαντλήθηκε το execution budget: \(reason)"
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
    case budgetExceeded
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
    static let runtimeFingerprint = "runtime-v1.13-unified-runner"

    private let runtime: AgentTaskRuntime
    private let orchestrator: AgentOrchestrator
    private let approvalGate: ApprovalGateService
    private let verifier: AgentStepVerifier

    private var leasedTaskIds: Set<UUID> = []
    private var activeCapabilityTasks: [UUID: Task<CapabilityOutcome, Error>] = [:]
    private var cancellationRequestedTaskIds: Set<UUID> = []

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

    func isTaskExecuting(_ taskId: UUID) -> Bool {
        leasedTaskIds.contains(taskId)
    }

    @discardableResult
    func requestCancellation(taskId: UUID, reason: String = "Cancelled by user") -> Bool {
        guard leasedTaskIds.contains(taskId) else { return false }
        cancellationRequestedTaskIds.insert(taskId)
        activeCapabilityTasks[taskId]?.cancel()
        runtime.pause(taskId: taskId, reason: reason)
        lastExecutionSummary = reason
        onProgress?("⏹️ \(reason)")
        return true
    }

    @discardableResult
    func executeNextStep(taskId: UUID, recentHistory: [ChatMessage] = []) async throws -> PlanStep? {
        try acquireExecutionLease(taskId: taskId)
        defer { releaseExecutionLease(taskId: taskId) }
        return try await executeNextStepWithLease(taskId: taskId, recentHistory: recentHistory)
    }

    @discardableResult
    private func executeNextStepWithLease(taskId: UUID, recentHistory: [ChatMessage]) async throws -> PlanStep? {
        guard leasedTaskIds.contains(taskId) else { throw AgentTaskExecutorError.taskAlreadyExecuting(taskId) }
        try throwIfCancellationRequested(taskId)
        guard let task = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
        guard task.status == .running else { throw AgentTaskExecutorError.taskNotRunning }
        guard let step = runtime.nextRunnableStep(taskId: taskId) else { throw AgentTaskExecutorError.noRunnableStep }

        if step.requiresApproval && step.status != .ready {
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
        guard orchestrator.capabilities.contains(where: { $0.id == capabilityId }) else {
            let error = AgentTaskExecutorError.missingCapability(capabilityId)
            runtime.markStepFailed(taskId: taskId, stepId: step.id, error: error.localizedDescription)
            throw error
        }

        runtime.markStepRunning(taskId: taskId, stepId: step.id)
        runtime.checkpoint(
            taskId: taskId,
            summary: "Executing step #\(step.order): \(step.title)",
            nextAction: "Run capability \(capabilityId) through UniversalCapabilityRunner"
        )

        let trace = "[TRAVIS \(Self.runtimeFingerprint) | capability=\(capabilityId) | step=\(step.order)]"
        onProgress?("\(trace)\nΕκτελώ step #\(step.order): \(step.title)")

        do {
            try throwIfCancellationRequested(taskId)
            let command = executionCommand(task: task, step: step)
            let projectId = ProjectWorkspaceStore.shared.project(containingTask: taskId)?.id

            let capabilityTask = Task<CapabilityOutcome, Error> { @MainActor [orchestrator] in
                try Task.checkCancellation()
                return try await orchestrator.executeCapability(
                    id: capabilityId,
                    command: command,
                    taskId: taskId,
                    stepId: step.id,
                    projectId: projectId,
                    recentHistory: recentHistory
                )
            }
            activeCapabilityTasks[taskId] = capabilityTask
            defer { activeCapabilityTasks[taskId] = nil }

            let outcome = try await capabilityTask.value
            try throwIfCancellationRequested(taskId)

            switch outcome {
            case .reply(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentTaskExecutorError.emptyCapabilityResult
                }

                let verification = try await AIExecutionScope.$context.withValue(
                    AIInvocationContext(
                        workload: .verification,
                        capabilityId: capabilityId,
                        taskId: taskId,
                        stepId: step.id,
                        projectId: projectId,
                        operation: "autonomous.step.verify"
                    )
                ) {
                    try await verifier.verify(
                        taskGoal: task.goal,
                        step: step,
                        capabilityResult: text
                    )
                }
                try throwIfCancellationRequested(taskId)

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
                    onProgress?("\(trace)\n✅ Step #\(step.order) ολοκληρώθηκε και επαληθεύτηκε.\n\(text)")
                    return runtime.nextRunnableStep(taskId: taskId)

                case .insufficientEvidence:
                    if capabilityId == "repository_context" {
                        let limitedResult = """
                        \(text)

                        VERIFICATION LIMITATION
                        \(verification.reason)
                        Unmet scope: \(verification.unmetCriteria.joined(separator: " | "))
                        """
                        runtime.markStepCompleted(taskId: taskId, stepId: step.id, resultSummary: limitedResult)
                        let checkpointSummary = "Step #\(step.order) completed with verified evidence limitation"
                        runtime.checkpoint(
                            taskId: taskId,
                            summary: checkpointSummary,
                            nextAction: runtime.nextRunnableStep(taskId: taskId)?.title
                        )
                        lastExecutionSummary = checkpointSummary
                        onProgress?("\(trace)\n⚠️ Step #\(step.order) ολοκληρώθηκε με περιορισμό evidence — το task συνεχίζει.\n\(limitedResult)")
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
                try throwIfCancellationRequested(taskId)
                approvalGate.submit(action)
                runtime.markStepWaitingForApproval(taskId: taskId, stepId: step.id)
                let message = "\(trace)\n🔐 Step #\(step.order) δημιούργησε ενέργεια που απαιτεί έγκριση."
                lastExecutionSummary = message
                onProgress?(message)
                return step

            case .none:
                throw AgentTaskExecutorError.emptyCapabilityResult
            }
        } catch is CancellationError {
            runtime.pause(taskId: taskId, reason: "Execution cancelled before verified completion")
            lastExecutionSummary = "Execution cancelled"
            onProgress?("\(trace)\n⏹️ Step #\(step.order) ακυρώθηκε με ασφάλεια πριν από verified completion.")
            throw CancellationError()
        } catch let error as UniversalCapabilityRunner.RunnerError {
            if case .timedOut(let seconds) = error {
                let mapped = AgentTaskExecutorError.capabilityTimedOut(seconds: seconds)
                if let latestTask = runtime.task(id: taskId),
                   let latestStep = latestTask.plan.steps.first(where: { $0.id == step.id }),
                   latestStep.status == .running {
                    runtime.markStepFailed(taskId: taskId, stepId: step.id, error: mapped.localizedDescription)
                }
                lastExecutionSummary = mapped.localizedDescription
                onProgress?("\(trace)\n⏱️ Step #\(step.order) timed out: \(mapped.localizedDescription)")
                throw mapped
            }
            throw error
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
        try acquireExecutionLease(taskId: taskId)
        defer { releaseExecutionLease(taskId: taskId) }

        guard let initialTask = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
        let retryBudgetPerStep = max(1, initialTask.budget.maxRetriesPerStep)
        let planAttemptBudget = max(1, initialTask.plan.steps.count * retryBudgetPerStep)
        let requestedBudget = max(1, maxStepsPerCycle)
        let safeLimit = min(max(requestedBudget, planAttemptBudget), 60)
        var attempted = 0

        while attempted < safeLimit {
            try throwIfCancellationRequested(taskId)
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

            if let budgetReason = budgetViolationReason(task) {
                runtime.pause(taskId: taskId, reason: "Execution budget exhausted: \(budgetReason)")
                guard let pausedTask = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
                lastExecutionSummary = "Execution budget exhausted: \(budgetReason)"
                onProgress?("⛔️ Execution budget exhausted: \(budgetReason)")
                return makeRunReport(task: pausedTask, reason: .budgetExceeded, stepsAttempted: attempted)
            }

            guard runtime.nextRunnableStep(taskId: taskId) != nil else {
                guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
                return makeRunReport(task: latest, reason: .noRunnableStep, stepsAttempted: attempted)
            }

            do {
                _ = try await executeNextStepWithLease(taskId: taskId, recentHistory: recentHistory)
                attempted += 1
            } catch is CancellationError {
                guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }
                return makeRunReport(task: latest, reason: .paused, stepsAttempted: attempted)
            } catch {
                attempted += 1
                guard let latest = runtime.task(id: taskId) else { throw AgentTaskExecutorError.taskNotFound }

                if latest.status == .running, let retryStep = runtime.nextRunnableStep(taskId: taskId) {
                    let backoffSeconds = min(Int(pow(2.0, Double(max(0, retryStep.attemptCount - 1)))), 8)
                    let retryMessage = retryStep.lastError.map {
                        "Retrying step #\(retryStep.order) in \(backoffSeconds)s (attempt \(retryStep.attemptCount + 1)/\(retryStep.maxAttempts)): \($0)"
                    } ?? "Retrying step #\(retryStep.order) in \(backoffSeconds)s: \(retryStep.title)"
                    onProgress?("↻ \(retryMessage)")
                    try? await Task.sleep(for: .seconds(backoffSeconds))
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

    private func budgetViolationReason(_ task: AgentTask) -> String? {
        if let maxSteps = task.budget.maxSteps {
            let totalExecutionAttempts = task.plan.steps.reduce(0) { $0 + $1.attemptCount }
            if totalExecutionAttempts >= maxSteps {
                return "step execution budget reached (\(totalExecutionAttempts)/\(maxSteps) attempts)"
            }
        }

        if let maxRuntimeSeconds = task.budget.maxRuntimeSeconds,
           let startedAt = task.startedAt {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= maxRuntimeSeconds {
                return "wall-clock runtime budget reached (\(Int(elapsed))s/\(Int(maxRuntimeSeconds))s)"
            }
        }
        return nil
    }

    private func throwIfCancellationRequested(_ taskId: UUID) throws {
        if Task.isCancelled || cancellationRequestedTaskIds.contains(taskId) {
            throw CancellationError()
        }
    }

    private func acquireExecutionLease(taskId: UUID) throws {
        guard !leasedTaskIds.contains(taskId) else {
            throw AgentTaskExecutorError.taskAlreadyExecuting(taskId)
        }
        cancellationRequestedTaskIds.remove(taskId)
        leasedTaskIds.insert(taskId)
        isExecuting = true
    }

    private func releaseExecutionLease(taskId: UUID) {
        activeCapabilityTasks[taskId]?.cancel()
        activeCapabilityTasks[taskId] = nil
        cancellationRequestedTaskIds.remove(taskId)
        leasedTaskIds.remove(taskId)
        isExecuting = !leasedTaskIds.isEmpty
    }

    private func makeRunReport(task: AgentTask, reason: AutonomousRunStopReason, stepsAttempted: Int) -> AutonomousRunReport {
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
        let dependencies = task.plan.steps.filter { dependencyIds.contains($0.id) }.sorted { $0.order < $1.order }
        var sections: [String] = []
        var totalCharacters = 0
        let maxTotalCharacters = 80_000
        let maxCharactersPerDependency = 14_000

        for dependency in dependencies {
            guard totalCharacters < maxTotalCharacters else { break }
            guard dependency.status == .completed,
                  let result = dependency.resultSummary,
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
    private let maxDecodeAttempts = 2

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func verify(taskGoal: String, step: PlanStep, capabilityResult: String) async throws -> StepVerificationResult {
        if let deterministic = DeterministicStepVerifier.verify(step: step, capabilityResult: capabilityResult) {
            return deterministic
        }

        let criteria = step.successCriteria.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let basePrompt = """
        You are the scope-aware verification component of TRAVIS.

        Verify ONLY the current step. The overall task goal is context, not an instruction to demand repository-wide completeness from this step.
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

        Return ONLY one JSON object with exactly this schema:
        {"verdict":"pass|retry|insufficient_evidence","confidence":0.0,"reason":"short reason","unmetCriteria":[]}

        Verdict rules:
        - pass: the current step's scoped criteria are demonstrated.
        - retry: evidence was available but the result is materially wrong, contradictory, malformed, or failed to use it.
        - insufficient_evidence: the result is honest and grounded, but the loaded evidence cannot establish part of the requested scope.
        - A stated limitation about OUT-OF-SCOPE repository areas is NOT a failure when the current step's own scope is satisfied.
        - Do not require tests, docs, generated artifacts, unrelated subsystems, or repository-wide classification unless the step explicitly requests them.
        - For repository-grounded results, a real source path plus a concrete symbol, control-flow branch, state transition, API call, or data-flow behavior is sufficient source evidence when it supports the claim.
        - Do NOT require exact line numbers unless the current step instructions or success criteria explicitly require line-level references.
        - confidence must be 0.0...1.0.
        - unmetCriteria lists only current-step criteria not demonstrated.
        """

        var lastRaw = ""
        var lastDiagnostic = "unknown decode error"

        for attempt in 1...maxDecodeAttempts {
            try Task.checkCancellation()
            let prompt: String
            if attempt == 1 {
                prompt = basePrompt
            } else {
                prompt = """
                Repair the following verifier response into VALID JSON ONLY.
                Do not change its substantive verdict unless necessary to fit the allowed enum.
                Required schema:
                {"verdict":"pass|retry|insufficient_evidence","confidence":0.0,"reason":"short reason","unmetCriteria":[]}

                MALFORMED RESPONSE:
                \(lastRaw)

                Return exactly one JSON object and nothing else.
                """
            }

            let raw = try await aiService.generateText(prompt: prompt, maxTokens: attempt == 1 ? 1200 : 500)
            try Task.checkCancellation()
            lastRaw = raw

            do {
                return try decodeVerifierResult(raw)
            } catch {
                lastDiagnostic = verifierDecodeDiagnostic(error)
            }
        }

        let preview = String(lastRaw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        throw AgentTaskExecutorError.verificationFailed("Verifier returned malformed JSON after \(maxDecodeAttempts) attempts. \(lastDiagnostic). Response preview: \(preview)")
    }

    private func decodeVerifierResult(_ raw: String) throws -> StepVerificationResult {
        let json = raw.extractFirstJSONObject() ?? raw.removingVerifierJSONFence()
        guard let data = json.data(using: .utf8) else {
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

    private func verifierDecodeDiagnostic(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .dataCorrupted(let context):
            return "dataCorrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            return decodingError.localizedDescription
        }
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

    func extractFirstJSONObject() -> String? {
        let chars = Array(self)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for index in chars.indices {
            let char = chars[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true; continue }
            if char == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if char == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start { return String(chars[start...index]) }
            }
        }
        return nil
    }
}
