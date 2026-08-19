import Foundation
import Observation

enum AutonomousMissionEngineV2State: String, Codable { case idle, planning, executing, correcting, waitingForApproval, completed, paused, failed }

struct AutonomousMissionV2Report: Codable, Hashable {
    let taskId: UUID
    let state: AutonomousMissionEngineV2State
    let planVersion: Int
    let replansUsed: Int
    let progress: Double
    let message: String
}

@MainActor
@Observable
final class AutonomousMissionEngineV2 {
    private let runtime: AgentTaskRuntime
    private let executor: AgentTaskExecutor
    private let orchestrator: AgentOrchestrator
    private let planner: AutonomousMissionPlannerV2
    private var reusedSkillByTask: [UUID: ReusableSkillStore.Skill] = [:]

    private(set) var state: AutonomousMissionEngineV2State = .idle
    private(set) var activeTaskId: UUID?
    private(set) var lastMessage: String = "Ready"
    var onProgress: ((String) -> Void)?

    init(runtime: AgentTaskRuntime, executor: AgentTaskExecutor, orchestrator: AgentOrchestrator, planner: AutonomousMissionPlannerV2? = nil) {
        self.runtime = runtime
        self.executor = executor
        self.orchestrator = orchestrator
        self.planner = planner ?? AutonomousMissionPlannerV2()
    }

    @discardableResult
    func startMission(goal: String, title: String? = nil, priority: AgentTaskPriority = .medium, budget: TaskExecutionBudget = TaskExecutionBudget(), recentHistory: [ChatMessage] = []) async throws -> AutonomousMissionV2Report {
        state = .planning
        lastMessage = "Σχεδιάζω την αποστολή…"
        onProgress?("🧠 TRAVIS: πρώτα ελέγχω αν ξέρω ήδη πώς γίνεται αυτή η αποστολή.")

        let task = runtime.createTask(goal: goal, title: title, priority: priority, budget: budget)
        activeTaskId = task.id

        do {
            let matureSkill = SkillExecutionEngine.shared.optimizedPlan(for: goal, capabilities: orchestrator.capabilities)
            let availableCapabilityIds = Set(orchestrator.capabilities.map(\.id))
            let localDecision = LocalMissionPlanReuse.makePlan(for: goal, from: runtime.tasks.filter { $0.id != task.id }, availableCapabilityIds: availableCapabilityIds)

            let plan: TaskPlan
            if let matureSkill {
                plan = matureSkill.plan
                reusedSkillByTask[task.id] = matureSkill.skill
                let mode = matureSkill.planningMode == .deterministic ? "LOCAL" : "LOCAL-AI"
                onProgress?("⚡ \(mode) SKILL: χρησιμοποιώ ώριμη δεξιότητα με \(Int(matureSkill.effectiveConfidence * 100))% εμπιστοσύνη. Δεν καλώ cloud planner.")
            } else if let localDecision {
                plan = localDecision.plan
                LocalIntelligenceMetrics.shared.record(.learnedMissionPlan)
                let percent = Int(localDecision.confidence * 100)
                onProgress?("🧠 LOCAL LEARNING: βρήκα verified προηγούμενη αποστολή με \(percent)% ομοιότητα. Χρησιμοποιώ το ήδη μαθημένο σχέδιο χωρίς AI planner.")
            } else {
                onProgress?("↗️ Δεν έχω ακόμη αρκετά σίγουρη δεξιότητα. Χρησιμοποιώ AI μόνο για το planning αυτής της νέας περίπτωσης.")
                let priorKnowledge = buildPriorExperienceContext(for: goal)
                plan = try await planner.makePlan(goal: goal, capabilities: orchestrator.capabilities, priorKnowledge: priorKnowledge)
            }

            runtime.attachPlan(taskId: task.id, plan: plan)
            runtime.start(taskId: task.id)
            state = .executing
            onProgress?("✅ Το σχέδιο είναι έτοιμο με \(plan.steps.count) βήματα. Ξεκινώ αυτόνομα.")
            return try await continueMission(taskId: task.id, recentHistory: recentHistory)
        } catch {
            runtime.pause(taskId: task.id, reason: "Mission planning failed: \(error.localizedDescription)")
            state = .failed
            lastMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func continueMission(taskId: UUID, recentHistory: [ChatMessage] = []) async throws -> AutonomousMissionV2Report {
        activeTaskId = taskId
        guard var task = runtime.task(id: taskId) else { state = .failed; throw AgentTaskExecutorError.taskNotFound }
        if task.status == .paused { runtime.resume(taskId: taskId); task = runtime.task(id: taskId) ?? task }
        if task.status == .pending { runtime.start(taskId: taskId); task = runtime.task(id: taskId) ?? task }

        var correctionCycles = task.executionState.replanCount
        let maxReplans = max(0, task.budget.maxReplans)

        while true {
            guard let current = runtime.task(id: taskId) else { state = .failed; throw AgentTaskExecutorError.taskNotFound }
            switch current.status {
            case .completed:
                rewardReusedSkill(taskId)
                state = .completed
                lastMessage = "Η αποστολή ολοκληρώθηκε και επαληθεύτηκε."
                onProgress?("🏁 TRAVIS: η αποστολή ολοκληρώθηκε με verified αποτέλεσμα.")
                return report(for: current, message: lastMessage)
            case .waitingForApproval:
                state = .waitingForApproval
                lastMessage = "Χρειάζομαι έγκριση για ένα ευαίσθητο βήμα."
                return report(for: current, message: lastMessage)
            case .cancelled:
                state = .paused
                lastMessage = "Η αποστολή ακυρώθηκε."
                return report(for: current, message: lastMessage)
            default: break
            }

            state = .executing
            let run = try await executor.executeUntilBlocked(taskId: taskId, recentHistory: recentHistory, maxStepsPerCycle: 12)
            guard let afterRun = runtime.task(id: taskId) else { state = .failed; throw AgentTaskExecutorError.taskNotFound }

            switch run.stopReason {
            case .completed:
                rewardReusedSkill(taskId)
                state = .completed
                lastMessage = "Η αποστολή ολοκληρώθηκε και επαληθεύτηκε."
                return report(for: afterRun, message: lastMessage)
            case .waitingForApproval:
                state = .waitingForApproval
                lastMessage = "Η αποστολή περιμένει έγκριση."
                return report(for: afterRun, message: lastMessage)
            case .paused, .budgetExceeded:
                state = .paused
                lastMessage = run.failureReason ?? afterRun.failureReason ?? "Η αποστολή σταμάτησε με ασφάλεια."
                return report(for: afterRun, message: lastMessage)
            case .safetyStepLimitReached:
                state = .executing
                runtime.checkpoint(taskId: taskId, summary: "Mission V2 cycle checkpoint after \(run.stepsAttempted) attempts", nextAction: run.nextStepTitle)
                onProgress?("↻ Συνεχίζω την αποστολή από το checkpoint χωρίς νέα εντολή.")
                continue
            case .noRunnableStep:
                if afterRun.status == .running { state = .paused; lastMessage = "Δεν υπάρχει εκτελέσιμο επόμενο βήμα. Χρειάζεται νέο σχέδιο." }
                else { lastMessage = afterRun.failureReason ?? "Δεν υπάρχει εκτελέσιμο επόμενο βήμα." }
                fallthrough
            case .failed:
                penalizeReusedSkill(taskId)
                guard correctionCycles < maxReplans else {
                    state = .failed
                    lastMessage = afterRun.failureReason ?? "Εξαντλήθηκαν οι αυτόματες διορθώσεις."
                    onProgress?("⛔️ Σταματώ: δοκίμασα τις επιτρεπόμενες αυτόματες διορθώσεις χωρίς verified completion.")
                    return report(for: afterRun, message: lastMessage)
                }
                correctionCycles += 1
                state = .correcting
                onProgress?("🛠️ Self-correction \(correctionCycles)/\(maxReplans): αναλύω τι απέτυχε και αλλάζω σχέδιο.")
                do {
                    let recoveryPlan = try await planner.makeRecoveryPlan(task: afterRun, capabilities: orchestrator.capabilities)
                    runtime.replacePlan(taskId: taskId, summary: recoveryPlan.summary, steps: recoveryPlan.steps)
                    runtime.start(taskId: taskId)
                    runtime.checkpoint(taskId: taskId, summary: "Recovery plan v\(recoveryPlan.version) attached after failure", nextAction: recoveryPlan.steps.first?.title)
                    onProgress?("✅ Δημιούργησα διαφορετικό recovery plan. Συνεχίζω αυτόματα.")
                    continue
                } catch {
                    state = .failed
                    lastMessage = "Απέτυχε και η αυτόματη διόρθωση: \(error.localizedDescription)"
                    runtime.pause(taskId: taskId, reason: lastMessage)
                    return report(for: runtime.task(id: taskId) ?? afterRun, message: lastMessage)
                }
            }
        }
    }

    func cancelActiveMission(reason: String = "Cancelled by user") {
        guard let activeTaskId else { return }
        if !executor.requestCancellation(taskId: activeTaskId, reason: reason) { runtime.cancel(taskId: activeTaskId, reason: reason) }
        state = .paused
        lastMessage = reason
    }

    private func rewardReusedSkill(_ taskId: UUID) {
        guard let skill = reusedSkillByTask.removeValue(forKey: taskId) else { return }
        SkillConfidenceStore.shared.recordSuccess(skill: skill)
        onProgress?("📈 Η μαθημένη δεξιότητα πέτυχε ξανά. Αυξάνω σταδιακά την εμπιστοσύνη της.")
    }

    private func penalizeReusedSkill(_ taskId: UUID) {
        guard let skill = reusedSkillByTask.removeValue(forKey: taskId) else { return }
        SkillConfidenceStore.shared.recordFailure(skill: skill)
        onProgress?("📉 Η μαθημένη δεξιότητα απέτυχε σε αυτή την περίπτωση. Μειώνω την εμπιστοσύνη και επιστρέφω σε ασφαλέστερη λύση.")
    }

    private func report(for task: AgentTask, message: String) -> AutonomousMissionV2Report {
        AutonomousMissionV2Report(taskId: task.id, state: state, planVersion: task.plan.version, replansUsed: task.executionState.replanCount, progress: runtime.progress(taskId: task.id), message: message)
    }

    private func buildPriorExperienceContext(for goal: String) -> String? {
        let normalizedWords = Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
        guard !normalizedWords.isEmpty else { return nil }
        let similar = runtime.tasks.filter { $0.status == .completed || $0.status == .failed }.compactMap { task -> (AgentTask, Int)? in
            let words = Set((task.title + " " + task.goal).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
            let score = normalizedWords.intersection(words).count
            return score > 0 ? (task, score) : nil
        }.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.updatedAt > rhs.0.updatedAt }.prefix(4)
        guard !similar.isEmpty else { return nil }
        return similar.map { task, _ in
            let completed = task.plan.steps.filter { $0.status == .completed }
            let failed = task.plan.steps.filter { $0.status == .failed }
            let completedText = completed.prefix(4).map { "✓ \($0.title): \(String(($0.resultSummary ?? "completed").prefix(900)))" }.joined(separator: "\n")
            let failedText = failed.prefix(2).map { "✗ \($0.title): \($0.lastError ?? "failed")" }.joined(separator: "\n")
            return "PRIOR MISSION: \(task.title)\nSTATUS: \(task.status.rawValue)\n\(completedText)\n\(failedText)"
        }.joined(separator: "\n\n")
    }
}
