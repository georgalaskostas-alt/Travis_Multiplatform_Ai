import Foundation
import Observation

enum AutonomousMissionEngineV2State: String, Codable { case idle, planning, executing, correcting, waitingForApproval, completed, paused, failed, handedOff }
struct AutonomousMissionV2Report: Codable, Hashable { let taskId:UUID;let state:AutonomousMissionEngineV2State;let planVersion:Int;let replansUsed:Int;let progress:Double;let message:String }

@MainActor @Observable final class AutonomousMissionEngineV2 {
    private let runtime:AgentTaskRuntime;private let executor:AgentTaskExecutor;private let orchestrator:AgentOrchestrator;private let planner:AutonomousMissionPlannerV2
    private var reusedSkillByTask:[UUID:ReusableSkillStore.Skill]=[:]
    private(set)var state:AutonomousMissionEngineV2State = .idle;private(set)var activeTaskId:UUID?;private(set)var lastMessage="Ready";var onProgress:((String)->Void)?
    init(runtime:AgentTaskRuntime,executor:AgentTaskExecutor,orchestrator:AgentOrchestrator,planner:AutonomousMissionPlannerV2?=nil){self.runtime=runtime;self.executor=executor;self.orchestrator=orchestrator;self.planner=planner ?? AutonomousMissionPlannerV2()}

    @discardableResult func startMission(goal:String,title:String?=nil,priority:AgentTaskPriority = .medium,budget:TaskExecutionBudget = TaskExecutionBudget(),recentHistory:[ChatMessage]=[])async throws->AutonomousMissionV2Report{
        state = .planning;lastMessage="Σχεδιάζω την αποστολή…";onProgress?("🧠 TRAVIS: πρώτα ελέγχω αν ξέρω ήδη πώς γίνεται αυτή η αποστολή.")
        let task=runtime.createTask(goal:goal,title:title,priority:priority,budget:budget);activeTaskId=task.id
        do{
            let mature=SkillExecutionEngine.shared.optimizedPlan(for:goal,capabilities:orchestrator.capabilities);let ids=Set(orchestrator.capabilities.map(\.id));let local=LocalMissionPlanReuse.makePlan(for:goal,from:runtime.tasks.filter{$0.id != task.id},availableCapabilityIds:ids)
            let plan:TaskPlan
            if let mature{plan=mature.plan;reusedSkillByTask[task.id]=mature.skill;onProgress?("⚡ LOCAL SKILL: χρησιμοποιώ ώριμη verified δεξιότητα.")}
            else if let local{plan=local.plan;LocalIntelligenceMetrics.shared.record(.learnedMissionPlan);onProgress?("🧠 LOCAL LEARNING: χρησιμοποιώ verified προηγούμενο σχέδιο χωρίς cloud planner.")}
            else{onProgress?("↗️ Χρησιμοποιώ AI planning για τη νέα περίπτωση.");plan=try await planner.makePlan(goal:goal,capabilities:orchestrator.capabilities,priorKnowledge:buildPriorExperienceContext(for:goal))}
            runtime.attachPlan(taskId:task.id,plan:plan)
            if let planned=runtime.task(id:task.id),case .success=HeadlessMissionHandoff.eligibility(task:planned){
                do{let handoff=try HeadlessMissionHandoff.export(task:planned);runtime.pause(taskId:task.id,reason:"Execution handed off to headless worker job \(handoff.jobID.uuidString)");state = .handedOff;lastMessage="Η Mission V2 παραδόθηκε στον Always-On worker (\(handoff.exportedSteps) steps). Μπορείς να κλείσεις το GUI.";onProgress?("♾️ HEADLESS HANDOFF: \(lastMessage)");return report(for:runtime.task(id:task.id) ?? planned,message:lastMessage)}catch HeadlessMissionHandoff.HandoffError.workerUnavailable{onProgress?("ℹ️ Ο headless worker δεν είναι διαθέσιμος· συνεχίζω με το κανονικό Mission V2 runtime.")}catch{onProgress?("ℹ️ Headless handoff δεν έγινε: \(error.localizedDescription). Συνεχίζω foreground.")}
            }
            runtime.start(taskId:task.id);state = .executing;onProgress?("✅ Το σχέδιο είναι έτοιμο με \(plan.steps.count) βήματα. Ξεκινώ αυτόνομα.");return try await continueMission(taskId:task.id,recentHistory:recentHistory)
        }catch{runtime.pause(taskId:task.id,reason:"Mission planning failed: \(error.localizedDescription)");state = .failed;lastMessage=error.localizedDescription;throw error}
    }

    @discardableResult func continueMission(taskId:UUID,recentHistory:[ChatMessage]=[])async throws->AutonomousMissionV2Report{
        activeTaskId=taskId;guard var task=runtime.task(id:taskId)else{state = .failed;throw AgentTaskExecutorError.taskNotFound};if task.status == .paused{runtime.resume(taskId:taskId);task=runtime.task(id:taskId) ?? task};if task.status == .pending{runtime.start(taskId:taskId);task=runtime.task(id:taskId) ?? task}
        var cycles=task.executionState.replanCount;let maxReplans=max(0,task.budget.maxReplans)
        while true{guard let current=runtime.task(id:taskId)else{state = .failed;throw AgentTaskExecutorError.taskNotFound};switch current.status{case .completed:rewardReusedSkill(taskId);state = .completed;lastMessage="Η αποστολή ολοκληρώθηκε και επαληθεύτηκε.";return report(for:current,message:lastMessage);case .waitingForApproval:state = .waitingForApproval;lastMessage="Χρειάζομαι έγκριση για ένα ευαίσθητο βήμα.";return report(for:current,message:lastMessage);case .cancelled:state = .paused;lastMessage="Η αποστολή ακυρώθηκε.";return report(for:current,message:lastMessage);default:break}
            state = .executing;let run=try await executor.executeUntilBlocked(taskId:taskId,recentHistory:recentHistory,maxStepsPerCycle:12);guard let after=runtime.task(id:taskId)else{state = .failed;throw AgentTaskExecutorError.taskNotFound}
            switch run.stopReason{case .completed:rewardReusedSkill(taskId);state = .completed;lastMessage="Η αποστολή ολοκληρώθηκε και επαληθεύτηκε.";return report(for:after,message:lastMessage);case .waitingForApproval:state = .waitingForApproval;lastMessage="Η αποστολή περιμένει έγκριση.";return report(for:after,message:lastMessage);case .paused,.budgetExceeded:state = .paused;lastMessage=run.failureReason ?? after.failureReason ?? "Η αποστολή σταμάτησε με ασφάλεια.";return report(for:after,message:lastMessage);case .safetyStepLimitReached:runtime.checkpoint(taskId:taskId,summary:"Mission V2 cycle checkpoint after \(run.stepsAttempted) attempts",nextAction:run.nextStepTitle);continue;case .noRunnableStep:if after.status == .running{state = .paused;lastMessage="Δεν υπάρχει εκτελέσιμο επόμενο βήμα."};fallthrough;case .failed:penalizeReusedSkill(taskId);guard cycles<maxReplans else{state = .failed;lastMessage=after.failureReason ?? "Εξαντλήθηκαν οι αυτόματες διορθώσεις.";return report(for:after,message:lastMessage)};cycles+=1;state = .correcting;do{let recovery=try await planner.makeRecoveryPlan(task:after,capabilities:orchestrator.capabilities);runtime.replacePlan(taskId:taskId,summary:recovery.summary,steps:recovery.steps);runtime.start(taskId:taskId);continue}catch{state = .failed;lastMessage="Απέτυχε η αυτόματη διόρθωση: \(error.localizedDescription)";runtime.pause(taskId:taskId,reason:lastMessage);return report(for:runtime.task(id:taskId) ?? after,message:lastMessage)}}
        }
    }
    func cancelActiveMission(reason:String="Cancelled by user"){guard let activeTaskId else{return};if !executor.requestCancellation(taskId:activeTaskId,reason:reason){runtime.cancel(taskId:activeTaskId,reason:reason)};state = .paused;lastMessage=reason}
    private func rewardReusedSkill(_ id:UUID){guard let s=reusedSkillByTask.removeValue(forKey:id)else{return};SkillConfidenceStore.shared.recordSuccess(skill:s)}
    private func penalizeReusedSkill(_ id:UUID){guard let s=reusedSkillByTask.removeValue(forKey:id)else{return};SkillConfidenceStore.shared.recordFailure(skill:s)}
    private func report(for task:AgentTask,message:String)->AutonomousMissionV2Report{.init(taskId:task.id,state:state,planVersion:task.plan.version,replansUsed:task.executionState.replanCount,progress:runtime.progress(taskId:task.id),message:message)}
    private func buildPriorExperienceContext(for goal:String)->String?{let words=Set(goal.lowercased().split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=4});guard !words.isEmpty else{return nil};let similar=runtime.tasks.filter{$0.status == .completed || $0.status == .failed}.compactMap{t->(AgentTask,Int)? in let w=Set((t.title+" "+t.goal).lowercased().split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=4});let score=words.intersection(w).count;return score>0 ? (t,score):nil}.sorted{$0.1 != $1.1 ? $0.1>$1.1:$0.0.updatedAt>$1.0.updatedAt}.prefix(4);guard !similar.isEmpty else{return nil};return similar.map{t,_ in "PRIOR MISSION: \(t.title)\nSTATUS: \(t.status.rawValue)"}.joined(separator:"\n\n")}
}
