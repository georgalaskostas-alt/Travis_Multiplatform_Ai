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
        case .taskAlreadyExecuting(let taskId): return "Το autonomous task \(taskId.uuidString) εκτελείται ήδη."
        case .missingCapability(let id): return "Δεν βρέθηκε capability με id \(id)."
        case .unassignedCapability: return "Το planner δεν ανέθεσε capability σε αυτό το step."
        case .verificationFailed(let reason): return "Η επαλήθευση του step απέτυχε: \(reason)"
        case .emptyCapabilityResult: return "Το capability δεν επέστρεψε αποτέλεσμα που μπορεί να επαληθευτεί."
        case .capabilityTimedOut(let seconds): return "Το capability ξεπέρασε το execution deadline των \(seconds) δευτερολέπτων."
        case .taskBudgetExceeded(let reason): return "Το autonomous task σταμάτησε επειδή εξαντλήθηκε το execution budget: \(reason)"
        }
    }
}

enum StepVerificationVerdict: String, Codable, Hashable { case pass, retry; case insufficientEvidence = "insufficient_evidence" }
struct StepVerificationResult: Codable, Hashable { let verdict: StepVerificationVerdict; let confidence: Double; let reason: String; let unmetCriteria: [String]; var passed: Bool { verdict == .pass } }
enum AutonomousRunStopReason: String, Codable, Hashable { case completed, waitingForApproval, paused, failed, noRunnableStep, safetyStepLimitReached, budgetExceeded }
struct AutonomousRunReport: Codable, Hashable { let taskId: UUID; let stopReason: AutonomousRunStopReason; let stepsAttempted: Int; let progress: Double; let lastCheckpoint: String?; let nextStepTitle: String?; let failureReason: String?; let nextStepAttemptCount: Int?; let nextStepMaxAttempts: Int?; let nextStepLastError: String? }

@MainActor @Observable
final class AgentTaskExecutor {
    static let runtimeFingerprint = "runtime-v1.14-learned-execution"
    private let runtime: AgentTaskRuntime; private let orchestrator: AgentOrchestrator; private let approvalGate: ApprovalGateService; private let verifier: AgentStepVerifier
    private var leasedTaskIds:Set<UUID>=[]; private var activeCapabilityTasks:[UUID:Task<CapabilityOutcome,Error>]=[:]; private var cancellationRequestedTaskIds:Set<UUID>=[]
    private(set) var isExecuting=false; private(set) var lastExecutionSummary:String?; var onProgress:((String)->Void)?
    init(runtime:AgentTaskRuntime,orchestrator:AgentOrchestrator,approvalGate:ApprovalGateService,verifier:AgentStepVerifier=AgentStepVerifier()){self.runtime=runtime;self.orchestrator=orchestrator;self.approvalGate=approvalGate;self.verifier=verifier}
    func isTaskExecuting(_ taskId:UUID)->Bool{leasedTaskIds.contains(taskId)}
    @discardableResult func requestCancellation(taskId:UUID,reason:String="Cancelled by user")->Bool{guard leasedTaskIds.contains(taskId) else{return false};cancellationRequestedTaskIds.insert(taskId);activeCapabilityTasks[taskId]?.cancel();runtime.pause(taskId:taskId,reason:reason);lastExecutionSummary=reason;onProgress?("⏹️ \(reason)");return true}
    @discardableResult func executeNextStep(taskId:UUID,recentHistory:[ChatMessage]=[]) async throws->PlanStep?{try acquireExecutionLease(taskId:taskId);defer{releaseExecutionLease(taskId:taskId)};return try await executeNextStepWithLease(taskId:taskId,recentHistory:recentHistory)}

    @discardableResult private func executeNextStepWithLease(taskId:UUID,recentHistory:[ChatMessage]) async throws->PlanStep?{
        guard leasedTaskIds.contains(taskId) else{throw AgentTaskExecutorError.taskAlreadyExecuting(taskId)};try throwIfCancellationRequested(taskId)
        guard let task=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};guard task.status == .running else{throw AgentTaskExecutorError.taskNotRunning};guard let step=runtime.nextRunnableStep(taskId:taskId) else{throw AgentTaskExecutorError.noRunnableStep}
        if step.requiresApproval && step.status != .ready{runtime.markStepWaitingForApproval(taskId:taskId,stepId:step.id);let m="Το step #\(step.order) περιμένει έγκριση: \(step.title)";lastExecutionSummary=m;onProgress?(m);return step}
        guard let capabilityId=step.capabilityId else{runtime.markStepFailed(taskId:taskId,stepId:step.id,error:AgentTaskExecutorError.unassignedCapability.localizedDescription);throw AgentTaskExecutorError.unassignedCapability}
        guard orchestrator.capabilities.contains(where:{$0.id==capabilityId}) else{let e=AgentTaskExecutorError.missingCapability(capabilityId);runtime.markStepFailed(taskId:taskId,stepId:step.id,error:e.localizedDescription);throw e}
        runtime.markStepRunning(taskId:taskId,stepId:step.id);runtime.checkpoint(taskId:taskId,summary:"Executing step #\(step.order): \(step.title)",nextAction:"Run capability \(capabilityId) through UniversalCapabilityRunner")
        let trace="[TRAVIS \(Self.runtimeFingerprint) | capability=\(capabilityId) | step=\(step.order)]";onProgress?("\(trace)\nΕκτελώ step #\(step.order): \(step.title)")
        do{
            try throwIfCancellationRequested(taskId);let projectId=ProjectWorkspaceStore.shared.project(containingTask:taskId)?.id
            let guidance=LearnedExecutionRegistry.shared.guidance(instruction:step.title+" "+step.instructions,capabilityId:capabilityId,projectId:projectId)
            if let guidance{onProgress?("🧠 Χρησιμοποιώ επιβεβαιωμένη προηγούμενη εμπειρία (\(Int(guidance.confidence*100))% ομοιότητα) πριν ζητήσω νέα νοημοσύνη.")}
            let command=executionCommand(task:task,step:step,learnedGuidance:guidance)
            let capabilityTask=Task<CapabilityOutcome,Error>{@MainActor [orchestrator] in try Task.checkCancellation();return try await orchestrator.executeCapability(id:capabilityId,command:command,taskId:taskId,stepId:step.id,projectId:projectId,recentHistory:recentHistory)}
            activeCapabilityTasks[taskId]=capabilityTask;defer{activeCapabilityTasks[taskId]=nil};let outcome=try await capabilityTask.value;try throwIfCancellationRequested(taskId)
            switch outcome{
            case .reply(let text):
                guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AgentTaskExecutorError.emptyCapabilityResult}
                let verification=try await AIExecutionScope.$context.withValue(AIInvocationContext(workload:.verification,capabilityId:capabilityId,taskId:taskId,stepId:step.id,projectId:projectId,operation:"autonomous.step.verify")){try await verifier.verify(taskGoal:task.goal,step:step,capabilityResult:text)};try throwIfCancellationRequested(taskId)
                switch verification.verdict{
                case .pass: runtime.markStepCompleted(taskId:taskId,stepId:step.id,resultSummary:text);let s="Step #\(step.order) verified with confidence "+String(format:"%.2f",verification.confidence);runtime.checkpoint(taskId:taskId,summary:s,nextAction:runtime.nextRunnableStep(taskId:taskId)?.title);lastExecutionSummary=s;onProgress?("\(trace)\n✅ Step #\(step.order) ολοκληρώθηκε και επαληθεύτηκε.\n\(text)");return runtime.nextRunnableStep(taskId:taskId)
                case .insufficientEvidence:
                    if capabilityId=="repository_context"{let limited="\(text)\n\nVERIFICATION LIMITATION\n\(verification.reason)\nUnmet scope: \(verification.unmetCriteria.joined(separator:" | "))";runtime.markStepCompleted(taskId:taskId,stepId:step.id,resultSummary:limited);let s="Step #\(step.order) completed with verified evidence limitation";runtime.checkpoint(taskId:taskId,summary:s,nextAction:runtime.nextRunnableStep(taskId:taskId)?.title);lastExecutionSummary=s;onProgress?("\(trace)\n⚠️ Step #\(step.order) ολοκληρώθηκε με περιορισμό evidence.\n\(limited)");return runtime.nextRunnableStep(taskId:taskId)}
                    let r=verification.reason;runtime.markStepFailed(taskId:taskId,stepId:step.id,error:r);throw AgentTaskExecutorError.verificationFailed(r)
                case .retry:let r=verification.reason;runtime.markStepFailed(taskId:taskId,stepId:step.id,error:r);throw AgentTaskExecutorError.verificationFailed(r)}
            case .proposal(let action):try throwIfCancellationRequested(taskId);approvalGate.submit(action);runtime.markStepWaitingForApproval(taskId:taskId,stepId:step.id);let m="\(trace)\n🔐 Step #\(step.order) δημιούργησε ενέργεια που απαιτεί έγκριση.";lastExecutionSummary=m;onProgress?(m);return step
            case .none:throw AgentTaskExecutorError.emptyCapabilityResult}
        }catch is CancellationError{runtime.pause(taskId:taskId,reason:"Execution cancelled before verified completion");lastExecutionSummary="Execution cancelled";onProgress?("\(trace)\n⏹️ Step #\(step.order) ακυρώθηκε με ασφάλεια.");throw CancellationError()}
        catch let error as UniversalCapabilityRunner.RunnerError{if case .timedOut(let seconds)=error{let mapped=AgentTaskExecutorError.capabilityTimedOut(seconds:seconds);if let t=runtime.task(id:taskId),let s=t.plan.steps.first(where:{$0.id==step.id}),s.status == .running{runtime.markStepFailed(taskId:taskId,stepId:step.id,error:mapped.localizedDescription)};lastExecutionSummary=mapped.localizedDescription;onProgress?("\(trace)\n⏱️ \(mapped.localizedDescription)");throw mapped};throw error}
        catch{if let t=runtime.task(id:taskId),let s=t.plan.steps.first(where:{$0.id==step.id}),s.status == .running{runtime.markStepFailed(taskId:taskId,stepId:step.id,error:error.localizedDescription)};lastExecutionSummary=error.localizedDescription;onProgress?("\(trace)\n❌ Step #\(step.order) απέτυχε: \(error.localizedDescription)");throw error}
    }

    func executeUntilBlocked(taskId:UUID,recentHistory:[ChatMessage]=[],maxStepsPerCycle:Int=8) async throws->AutonomousRunReport{
        try acquireExecutionLease(taskId:taskId);defer{releaseExecutionLease(taskId:taskId)};guard let initial=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};let retry=max(1,initial.budget.maxRetriesPerStep);let safeLimit=min(max(max(1,maxStepsPerCycle),max(1,initial.plan.steps.count*retry)),60);var attempted=0
        while attempted<safeLimit{try throwIfCancellationRequested(taskId);guard let task=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};switch task.status{case .completed:return makeRunReport(task:task,reason:.completed,stepsAttempted:attempted);case .waitingForApproval:return makeRunReport(task:task,reason:.waitingForApproval,stepsAttempted:attempted);case .paused:return makeRunReport(task:task,reason:.paused,stepsAttempted:attempted);case .failed,.cancelled:return makeRunReport(task:task,reason:.failed,stepsAttempted:attempted);case .pending,.planning,.waitingForDependency:return makeRunReport(task:task,reason:.noRunnableStep,stepsAttempted:attempted);case .running:break}
            if let r=budgetViolationReason(task){runtime.pause(taskId:taskId,reason:"Execution budget exhausted: \(r)");guard let p=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};return makeRunReport(task:p,reason:.budgetExceeded,stepsAttempted:attempted)}
            guard runtime.nextRunnableStep(taskId:taskId) != nil else{guard let latest=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};return makeRunReport(task:latest,reason:.noRunnableStep,stepsAttempted:attempted)}
            do{_ = try await executeNextStepWithLease(taskId:taskId,recentHistory:recentHistory);attempted+=1}catch is CancellationError{guard let l=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};return makeRunReport(task:l,reason:.paused,stepsAttempted:attempted)}catch{attempted+=1;guard let latest=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};if latest.status == .running,let retryStep=runtime.nextRunnableStep(taskId:taskId){let seconds=min(Int(pow(2.0,Double(max(0,retryStep.attemptCount-1)))),8);if seconds>0{try? await Task.sleep(for:.seconds(seconds))};continue};if latest.status == .failed || latest.status == .cancelled{return makeRunReport(task:latest,reason:.failed,stepsAttempted:attempted)};throw error};await Task.yield()}
        guard let latest=runtime.task(id:taskId) else{throw AgentTaskExecutorError.taskNotFound};return makeRunReport(task:latest,reason:.safetyStepLimitReached,stepsAttempted:attempted)
    }
    private func budgetViolationReason(_ task:AgentTask)->String?{if let m=task.budget.maxSteps{let n=task.plan.steps.reduce(0){$0+$1.attemptCount};if n>=m{return "step execution budget reached (\(n)/\(m) attempts)"}};if let m=task.budget.maxRuntimeSeconds,let s=task.startedAt{let e=Date().timeIntervalSince(s);if e>=m{return "wall-clock runtime budget reached (\(Int(e))s/\(Int(m))s)"}};return nil}
    private func throwIfCancellationRequested(_ id:UUID)throws{if Task.isCancelled || cancellationRequestedTaskIds.contains(id){throw CancellationError()}}
    private func acquireExecutionLease(taskId:UUID)throws{guard !leasedTaskIds.contains(taskId) else{throw AgentTaskExecutorError.taskAlreadyExecuting(taskId)};cancellationRequestedTaskIds.remove(taskId);leasedTaskIds.insert(taskId);isExecuting=true}
    private func releaseExecutionLease(taskId:UUID){activeCapabilityTasks[taskId]?.cancel();activeCapabilityTasks[taskId]=nil;cancellationRequestedTaskIds.remove(taskId);leasedTaskIds.remove(taskId);isExecuting = !leasedTaskIds.isEmpty}
    private func makeRunReport(task:AgentTask,reason:AutonomousRunStopReason,stepsAttempted:Int)->AutonomousRunReport{let n=runtime.nextRunnableStep(taskId:task.id);return AutonomousRunReport(taskId:task.id,stopReason:reason,stepsAttempted:stepsAttempted,progress:runtime.progress(taskId:task.id),lastCheckpoint:task.executionState.lastCheckpoint?.summary,nextStepTitle:n?.title,failureReason:task.failureReason,nextStepAttemptCount:n?.attemptCount,nextStepMaxAttempts:n?.maxAttempts,nextStepLastError:n?.lastError)}

    private func executionCommand(task:AgentTask,step:PlanStep,learnedGuidance:LearnedExecutionRegistry.Guidance?)->String{
        let criteria=step.successCriteria.enumerated().map{"\($0.offset+1). \($0.element)"}.joined(separator:"\n");let deps=dependencyEvidenceBlock(task:task,step:step)
        let learned:String
        if let g=learnedGuidance{learned="""
        VERIFIED PRIOR EXPERIENCE (guidance only — never copy blindly):
        confidence: \(Int(g.confidence*100))%
        same project: \(g.sameProject ? "yes" : "no")
        prior instruction: \(g.priorInstruction)
        prior verified result: \(g.priorVerifiedResult)

        Use this only as a proven precedent. Re-run the current work against current evidence. If current state differs, ignore the precedent.
        """}else{learned="No sufficiently similar verified prior experience."}
        return """
        RUNTIME FINGERPRINT: \(Self.runtimeFingerprint)
        Εκτελείς ένα συγκεκριμένο βήμα ενός ήδη εγκεκριμένου execution plan του TRAVIS.
        ΣΥΝΟΛΙΚΟΣ ΣΤΟΧΟΣ: \(task.goal)
        ΤΡΕΧΟΝ STEP: #\(step.order) — \(step.title)
        ΟΔΗΓΙΕΣ: \(step.instructions)
        VERIFIED DEPENDENCY EVIDENCE: \(deps)
        \(learned)
        SUCCESS CRITERIA: \(criteria)
        Παρήγαγε το πραγματικό αποτέλεσμα μόνο αυτού του step. Μην θεωρήσεις το παλιό αποτέλεσμα τρέχον evidence. Μην προχωρήσεις σε επόμενο step.
        """
    }
    private func dependencyEvidenceBlock(task:AgentTask,step:PlanStep)->String{guard !step.dependencyStepIds.isEmpty else{return "None — this step has no dependencies."};let ids=Set(step.dependencyStepIds);let dependencies=task.plan.steps.filter{ids.contains($0.id)}.sorted{$0.order<$1.order};var sections:[String]=[];var total=0;for d in dependencies{guard total<80_000 else{break};guard d.status == .completed,let r=d.resultSummary,!r.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{sections.append("--- DEPENDENCY STEP #\(d.order): \(d.title) ---\nNo verified result is available.");continue};let allowed=min(14_000,80_000-total);let clipped=String(r.prefix(allowed));sections.append("--- DEPENDENCY STEP #\(d.order): \(d.title) ---\n\(clipped)");total+=clipped.count};return sections.isEmpty ? "No completed dependency evidence is available." : sections.joined(separator:"\n\n")}
}

final class AgentStepVerifier {
    private let aiService:AIService;private let maxDecodeAttempts=2
    init(aiService:AIService = .shared){self.aiService=aiService}
    func verify(taskGoal:String,step:PlanStep,capabilityResult:String) async throws->StepVerificationResult{
        if let d=DeterministicStepVerifier.verify(step:step,capabilityResult:capabilityResult){return d}
        if let learned=LearnedVerificationRegistry.shared.verify(step:step,capabilityResult:capabilityResult){return learned}
        let criteria=step.successCriteria.enumerated().map{"\($0.offset+1). \($0.element)"}.joined(separator:"\n")
        let base="""You are the scope-aware verification component of TRAVIS. Verify ONLY the current step. Judge only evidence in the produced result. OVERALL GOAL: \(taskGoal) CURRENT STEP: \(step.title) INSTRUCTIONS: \(step.instructions) SUCCESS CRITERIA: \(criteria) PRODUCED RESULT: \(capabilityResult) Return ONLY JSON: {\"verdict\":\"pass|retry|insufficient_evidence\",\"confidence\":0.0,\"reason\":\"short reason\",\"unmetCriteria\":[]}"""
        var lastRaw="";var diagnostic="unknown decode error"
        for attempt in 1...maxDecodeAttempts{try Task.checkCancellation();let prompt=attempt==1 ? base : "Repair into valid verifier JSON only: \(lastRaw)";let raw=try await aiService.generateText(prompt:prompt,maxTokens:attempt==1 ? 1200:500);lastRaw=raw;do{return try decodeVerifierResult(raw)}catch{diagnostic=error.localizedDescription}}
        throw AgentTaskExecutorError.verificationFailed("Verifier returned malformed JSON. \(diagnostic)")
    }
    private func decodeVerifierResult(_ raw:String)throws->StepVerificationResult{let json=raw.extractFirstJSONObject() ?? raw.removingVerifierJSONFence();guard let data=json.data(using:.utf8) else{throw AgentTaskExecutorError.verificationFailed("Verifier response was not UTF-8 JSON.")};let r=try JSONDecoder().decode(StepVerificationResult.self,from:data);return StepVerificationResult(verdict:r.verdict,confidence:min(max(r.confidence,0),1),reason:r.reason,unmetCriteria:r.unmetCriteria)}
}
private extension String{func removingVerifierJSONFence()->String{var v=trimmingCharacters(in:.whitespacesAndNewlines);if v.hasPrefix("```json"){v.removeFirst(7)}else if v.hasPrefix("```"){v.removeFirst(3)};v=v.trimmingCharacters(in:.whitespacesAndNewlines);if v.hasSuffix("```"){v.removeLast(3)};return v.trimmingCharacters(in:.whitespacesAndNewlines)};func extractFirstJSONObject()->String?{let c=Array(self);var start:Int?;var depth=0;var inString=false;var escaped=false;for i in c.indices{let ch=c[i];if inString{if escaped{escaped=false}else if ch=="\\"{escaped=true}else if ch=="\""{inString=false};continue};if ch=="\""{inString=true;continue};if ch=="{"{if depth==0{start=i};depth+=1}else if ch=="}",depth>0{depth-=1;if depth==0,let s=start{return String(c[s...i])}}};return nil}}
