import Foundation
import Observation

@MainActor
@Observable
final class AgentTaskRuntime {
    private(set) var tasks: [AgentTask] = []
    private let store: AgentTaskStore
    private let policyEngine = AgentPolicyEngine()
    private(set) var persistenceError: String?

    init(store: AgentTaskStore = .shared) { self.store = store; restorePersistedTasks() }

    @discardableResult
    func createTask(goal: String, title: String? = nil, priority: AgentTaskPriority = .medium, dueDate: Date? = nil, budget: TaskExecutionBudget = TaskExecutionBudget()) -> AgentTask {
        var task = AgentTask(goal: goal, title: title, priority: priority, dueDate: dueDate, budget: budget)
        task.events.append(TaskEvent(type: .created, message: "Task created"))
        let previous = tasks
        tasks.append(task)
        persistOrRollback(to: previous)
        return task
    }
    func task(id: UUID) -> AgentTask? { tasks.first { $0.id == id } }

    /// Removes a terminal task from the in-memory runtime and durable store atomically from the UI's point of view.
    /// Active/paused missions are deliberately protected so deletion can never destroy execution ownership.
    @discardableResult
    func deleteTerminalTask(id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard [.completed, .failed, .cancelled].contains(tasks[index].status) else { return false }
        let previous = tasks
        tasks.remove(at: index)
        persistOrRollback(to: previous)
        return persistenceError == nil
    }

    /// Deletes only terminal history. Running, planning, approval, dependency and paused missions survive untouched.
    @discardableResult
    func deleteAllTerminalTasks() -> Int {
        let before = tasks.count
        let previous = tasks
        tasks.removeAll { [.completed, .failed, .cancelled].contains($0.status) }
        let deleted = before - tasks.count
        if deleted > 0 {
            persistOrRollback(to: previous)
            if persistenceError != nil { return 0 }
        }
        return deleted
    }

    func markPlanning(taskId: UUID, message: String = "Planning autonomous mission") { mutate(taskId) { task in guard ![.completed,.cancelled,.failed].contains(task.status) else{return};task.status = .planning;task.failureReason=nil;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.progress,message:message)) } }
    func failTask(taskId: UUID, reason: String) { mutate(taskId) { task in guard ![.completed,.cancelled].contains(task.status) else{return};task.status = .failed;task.failureReason=reason;task.completedAt=Date();task.executionState.currentStepId=nil;task.executionState.nextEligibleRunAt=nil;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.failed,message:reason)) } }
    func dispatchableTasks(backgroundOnly: Bool=false,limit:Int=8,now:Date=Date())->[AgentTask]{let bounded=max(1,min(limit,64));return tasks.filter{task in guard task.status == .running else{return false};if let next=task.executionState.nextEligibleRunAt,next>now{return false};guard let step=nextRunnableStep(taskId:task.id,now:now) else{return false};return !backgroundOnly || step.canRunInBackground}.sorted(by:schedulerPrecedes).prefix(bounded).map{$0}}
    func staleRunningTasks(heartbeatOlderThan interval:TimeInterval,now:Date=Date())->[AgentTask]{let threshold=now.addingTimeInterval(-max(1,interval));return tasks.filter{task in guard task.status == .running else{return false};guard let heartbeat=task.executionState.lastHeartbeatAt else{return true};return heartbeat<threshold}.sorted(by:schedulerPrecedes)}
    func attachPlan(taskId:UUID,plan:TaskPlan){mutate(taskId){task in task.plan=applyPolicy(to:plan);task.status = .pending;task.failureReason=nil;task.executionState.currentStepId=nil;task.executionState.consecutiveFailures=0;task.events.append(TaskEvent(type:.planned,message:"Plan attached: \(task.plan.summary)"))}}
    func replacePlan(taskId:UUID,summary:String,steps:[PlanStep]){mutate(taskId){task in let next=task.plan.steps.isEmpty ? 1:task.plan.version+1;task.plan=applyPolicy(to:TaskPlan(version:next,summary:summary,steps:steps));task.status = .pending;task.failureReason=nil;task.executionState.currentStepId=nil;task.executionState.consecutiveFailures=0;if next>1{task.executionState.replanCount+=1};task.events.append(TaskEvent(type:next==1 ? .planned:.replanned,message:summary))}}
    func start(taskId:UUID){mutate(taskId){task in guard ![.completed,.cancelled].contains(task.status) else{return};guard !task.plan.steps.isEmpty else{task.status = .failed;task.failureReason="Cannot start task without an execution plan.";task.events.append(TaskEvent(type:.failed,message:"Task cannot start because no execution plan exists."));return};if task.startedAt==nil{task.startedAt=Date()};task.status = .running;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.started,message:"Task execution started"))}}
    func pause(taskId:UUID,reason:String="Paused"){mutate(taskId){task in guard [.running,.waitingForDependency,.waitingForApproval].contains(task.status) else{return};if let sid=task.executionState.currentStepId,let i=task.plan.steps.firstIndex(where:{$0.id==sid}),task.plan.steps[i].status == .running{task.plan.steps[i].status = .pending;task.plan.steps[i].lastError=reason};task.executionState.currentStepId=nil;task.executionState.nextEligibleRunAt=nil;task.executionState.lastHeartbeatAt=Date();task.status = .paused;task.events.append(TaskEvent(type:.paused,message:reason))}}
    func resume(taskId:UUID){mutate(taskId){task in guard task.status == .paused else{return};task.status = .running;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.resumed,message:"Task resumed"))}}
    func cancel(taskId:UUID,reason:String="Cancelled by user"){mutate(taskId){task in guard ![.completed,.cancelled].contains(task.status) else{return};task.status = .cancelled;task.completedAt=Date();task.executionState.currentStepId=nil;task.events.append(TaskEvent(type:.cancelled,message:reason))}}
    @discardableResult func prepareRetry(taskId:UUID)->Bool{var prepared=false;mutate(taskId){task in guard task.status == .failed,let i=task.plan.steps.firstIndex(where:{$0.status == .failed}) else{return};task.plan.steps[i].status = .pending;task.plan.steps[i].attemptCount=0;task.plan.steps[i].lastError=nil;task.plan.steps[i].completedAt=nil;task.failureReason=nil;task.completedAt=nil;task.executionState.currentStepId=nil;task.executionState.consecutiveFailures=0;task.executionState.nextEligibleRunAt=nil;task.executionState.lastHeartbeatAt=Date();task.status = .running;task.events.append(TaskEvent(type:.retry,message:"Explicit retry prepared for step \(task.plan.steps[i].order): \(task.plan.steps[i].title)"));prepared=true};return prepared}
    func nextRunnableStep(taskId:UUID)->PlanStep?{nextRunnableStep(taskId:taskId,now:Date())}
    private func nextRunnableStep(taskId:UUID,now:Date)->PlanStep?{guard let task=task(id:taskId),task.status == .running else{return nil};if let next=task.executionState.nextEligibleRunAt,next>now{return nil};let completed=Set(task.plan.steps.filter{$0.status == .completed}.map(\.id));return task.plan.steps.sorted{$0.order<$1.order}.first{step in guard step.status == .pending || step.status == .ready else{return false};return step.dependencyStepIds.allSatisfy{completed.contains($0)}}}
    func markStepRunning(taskId:UUID,stepId:UUID){mutate(taskId){task in guard task.status == .running,let i=task.plan.steps.firstIndex(where:{$0.id==stepId}) else{return};let step=task.plan.steps[i];guard step.status == .pending || step.status == .ready else{return};task.executionState.currentStepId=stepId;task.executionState.lastHeartbeatAt=Date();task.plan.steps[i].status = .running;task.plan.steps[i].attemptCount+=1;if task.plan.steps[i].startedAt==nil{task.plan.steps[i].startedAt=Date()};task.events.append(TaskEvent(type:.progress,message:"Started step \(step.order): \(step.title)"))}}
    func markStepCompleted(taskId:UUID,stepId:UUID,resultSummary:String?=nil){mutate(taskId){task in guard let i=task.plan.steps.firstIndex(where:{$0.id==stepId}) else{return};task.plan.steps[i].status = .completed;task.plan.steps[i].completedAt=Date();task.plan.steps[i].resultSummary=resultSummary;task.plan.steps[i].lastError=nil;task.executionState.currentStepId=nil;task.executionState.consecutiveFailures=0;task.executionState.lastHeartbeatAt=Date();task.executionState.nextEligibleRunAt=nil;task.events.append(TaskEvent(type:.progress,message:"Completed step \(task.plan.steps[i].order): \(task.plan.steps[i].title)"));let unfinished=task.plan.steps.contains{![.completed,.skipped,.cancelled].contains($0.status)};if unfinished{task.status = .running}else{task.status = .completed;task.completedAt=Date();task.events.append(TaskEvent(type:.completed,message:"All plan steps completed"))}}}
    func markStepFailed(taskId:UUID,stepId:UUID,error:String){mutate(taskId){task in guard let i=task.plan.steps.firstIndex(where:{$0.id==stepId}) else{return};task.plan.steps[i].lastError=error;task.executionState.currentStepId=nil;task.executionState.consecutiveFailures+=1;task.executionState.lastHeartbeatAt=Date();let allowed=min(task.plan.steps[i].maxAttempts,task.budget.maxRetriesPerStep);if task.plan.steps[i].attemptCount<allowed{task.plan.steps[i].status = .pending;task.events.append(TaskEvent(type:.retry,message:"Step will retry: \(task.plan.steps[i].title) — \(error)"))}else{task.plan.steps[i].status = .failed;task.status = .failed;task.failureReason=error;task.completedAt=Date();task.events.append(TaskEvent(type:.failed,message:"Step exhausted retries: \(task.plan.steps[i].title) — \(error)"))}}}
    func markStepWaitingForApproval(taskId:UUID,stepId:UUID){mutate(taskId){task in guard let i=task.plan.steps.firstIndex(where:{$0.id==stepId}) else{return};task.plan.steps[i].status = .waitingForApproval;task.status = .waitingForApproval;task.executionState.currentStepId=stepId;task.events.append(TaskEvent(type:.approvalRequested,message:"Approval required for step \(task.plan.steps[i].order): \(task.plan.steps[i].title)"))}}
    func markStepApprovalGranted(taskId:UUID,stepId:UUID){mutate(taskId){task in guard let i=task.plan.steps.firstIndex(where:{$0.id==stepId}),task.plan.steps[i].status == .waitingForApproval else{return};task.plan.steps[i].requiresApproval=false;task.plan.steps[i].status = .ready;task.status = .running;task.executionState.currentStepId=nil;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.approvalGranted,message:"Approval granted for step \(task.plan.steps[i].order)"))}}
    func markStepApprovalRejected(taskId:UUID,stepId:UUID,reason:String="Approval rejected"){mutate(taskId){task in guard let i=task.plan.steps.firstIndex(where:{$0.id==stepId}) else{return};task.plan.steps[i].status = .cancelled;task.status = .paused;task.executionState.currentStepId=nil;task.events.append(TaskEvent(type:.approvalRejected,message:reason))}}
    func checkpoint(taskId:UUID,summary:String,nextAction:String?=nil){mutate(taskId){task in let checkpoint=TaskCheckpoint(taskId:task.id,stepId:task.executionState.currentStepId,summary:summary,nextAction:nextAction);task.executionState.lastCheckpoint=checkpoint;task.executionState.lastHeartbeatAt=Date();task.events.append(TaskEvent(type:.checkpoint,message:summary))}}
    func heartbeat(taskId:UUID,nextEligibleRunAt:Date?=nil){mutate(taskId){task in task.executionState.lastHeartbeatAt=Date();task.executionState.nextEligibleRunAt=nextEligibleRunAt}}
    func progress(taskId:UUID)->Double{guard let task=task(id:taskId),!task.plan.steps.isEmpty else{return 0};let completed=task.plan.steps.filter{$0.status == .completed || $0.status == .skipped}.count;return Double(completed)/Double(task.plan.steps.count)}
    func reloadFromDisk(){restorePersistedTasks()}
    private func applyPolicy(to plan:TaskPlan)->TaskPlan{var plan=plan;for i in plan.steps.indices{guard let capabilityId=plan.steps[i].capabilityId else{continue};switch policyEngine.evaluate(step:plan.steps[i],capabilityId:capabilityId){case .allow:break;case .requireApproval:plan.steps[i].requiresApproval=true;plan.steps[i].canRunInBackground=false;case .deny(let reason):plan.steps[i].requiresApproval=true;plan.steps[i].canRunInBackground=false;plan.steps[i].lastError="Policy denied autonomous execution: \(reason)"}};return plan}
    private func schedulerPrecedes(_ lhs:AgentTask,_ rhs:AgentTask)->Bool{let lp=priorityRank(lhs.priority),rp=priorityRank(rhs.priority);if lp != rp{return lp>rp};switch(lhs.dueDate,rhs.dueDate){case let(left?,right?) where left != right:return left<right;case(_?,nil):return true;case(nil,_?):return false;default:break};if lhs.updatedAt != rhs.updatedAt{return lhs.updatedAt<rhs.updatedAt};return lhs.id.uuidString<rhs.id.uuidString}
    private func priorityRank(_ p:AgentTaskPriority)->Int{switch p{case .low:return 0;case .medium:return 1;case .high:return 2;case .critical:return 3}}
    private func mutate(_ taskId:UUID,_ body:(inout AgentTask)->Void){
        guard let i=tasks.firstIndex(where:{$0.id==taskId}) else{return}
        let previous=tasks
        body(&tasks[i]);tasks[i].updatedAt=Date();tasks[i].plan.updatedAt=Date()
        persistOrRollback(to:previous)
    }
    private func persistOrRollback(to previous:[AgentTask]){
        do{try store.save(tasks);persistenceError=nil}
        catch{tasks=previous;persistenceError=error.localizedDescription;print("TRAVIS runtime persistence failed; mutation rolled back: \(error.localizedDescription)")}
    }
    private func persist(){do{try store.save(tasks);persistenceError=nil}catch{persistenceError=error.localizedDescription;print("TRAVIS runtime persistence failed: \(error.localizedDescription)")}}
    private func restorePersistedTasks(){
        do{
            let durable=try store.load()
            var recovered=durable
            for ti in recovered.indices{
                recovered[ti].plan=applyPolicy(to:recovered[ti].plan)
                guard recovered[ti].status == .running else{continue}
                if let sid=recovered[ti].executionState.currentStepId,
                   let si=recovered[ti].plan.steps.firstIndex(where:{$0.id==sid}),
                   recovered[ti].plan.steps[si].status == .running{
                    recovered[ti].plan.steps[si].status = .pending
                    recovered[ti].plan.steps[si].lastError="Recovered after process interruption before verified completion."
                }
                recovered[ti].executionState.currentStepId=nil
                recovered[ti].status = .paused
                recovered[ti].events.append(TaskEvent(type:.paused,message:"Recovered from durable snapshot after process interruption"))
                recovered[ti].updatedAt=Date()
            }

            // Recovery is accepted in memory only after the recovered snapshot
            // is durably committed. If that write fails, keep the original
            // durable state visible and block further mutation with an error.
            if recovered != durable {
                try store.save(recovered)
            }
            tasks=recovered
            persistenceError=nil
        }catch{
            tasks=[]
            persistenceError=error.localizedDescription
            print("TRAVIS runtime recovery blocked: \(error.localizedDescription)")
        }
    }
}
