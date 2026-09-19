import Foundation
import Observation

@MainActor
@Observable
final class AgentOrchestrator {
    private(set) var capabilities:[AgentCapability]=[]
    let approvalGate:ApprovalGateService
    private let sessionRecallService:SessionRecallService
    private let taskStore:AgentTaskStore
    private let capabilityRunner:UniversalCapabilityRunner
    var onAssistantMessage:((String)->Void)?
    var onSessionRecall:((UUID)->Void)?

    init(approvalGate:ApprovalGateService,sessionRecallService:SessionRecallService?=nil,taskStore:AgentTaskStore = .shared,capabilityRunner:UniversalCapabilityRunner = .shared){
        self.approvalGate=approvalGate;self.sessionRecallService=sessionRecallService ?? SessionRecallService();self.taskStore=taskStore;self.capabilityRunner=capabilityRunner
        let codingCapability=CodingRepositoryCapability();let builtIns:[AgentCapability]=[RepositoryContextCapability(),codingCapability,WebResearchCapability(),PublicAPICapability(),ManagedFilesCapability(),DocumentProcessingCapability(),HeadlessReasoningCapability()]
        for capability in builtIns{capabilities.append(capability);approvalGate.register(capability:capability)}
        codingCapability.onExecutionUpdate={ [weak self] text in self?.onAssistantMessage?(text) }
    }
    func register(_ capability:AgentCapability){guard !capabilities.contains(where:{$0.id==capability.id})else{return};capabilities.append(capability);approvalGate.register(capability:capability)}

    func route(_ message:String,liveSessionId:UUID,recentHistory:[ChatMessage]) async {
        let trimmed=message.trimmingCharacters(in:.whitespacesAndNewlines),lowered=trimmed.lowercased()
        if lowered=="/tasks"{onAssistantMessage?(renderTaskHistory());return}
        if lowered=="/task-status"{onAssistantMessage?(renderTaskStatus(reference:nil));return}
        if lowered.hasPrefix("/task-status "){onAssistantMessage?(renderTaskStatus(reference:String(trimmed.dropFirst("/task-status ".count)).trimmingCharacters(in:.whitespacesAndNewlines)));return}
        if lowered=="/task-log"{onAssistantMessage?(renderTaskLog(reference:nil));return}
        if lowered.hasPrefix("/task-log "){onAssistantMessage?(renderTaskLog(reference:String(trimmed.dropFirst("/task-log ".count)).trimmingCharacters(in:.whitespacesAndNewlines)));return}
        if lowered=="/capabilities"{onAssistantMessage?(CapabilityRegistry(capabilities:capabilities).diagnosticReport());return}
        if lowered=="/capability-log"{onAssistantMessage?(CapabilityExecutionJournal.shared.diagnosticReport());return}
        if lowered=="/ai-cost"{onAssistantMessage?(AIUsageLedger.shared.diagnosticReport());return}
        if lowered=="/learning"{onAssistantMessage?(VerifiedLearningStore.shared.diagnosticReport()+"\n\n"+VerifiedRoutingMemory.shared.diagnosticReport());return}
        if lowered=="/intelligence"{TravisLearningService.shared.refresh();let learning=TravisLearningService.shared;onAssistantMessage?("""
TRAVIS COGNITIVE CORE

AI ROUTING
local/deterministic → Luna → Terra → Sol frontier escalation

LEARNING
verified examples: \(VerifiedLearningStore.shared.examples.count)
learned routes: \(learning.learnedRoutes)
learning confidence: \(Int(learning.confidence*100))%
best known route: \(learning.bestKnownRoute)

COST GOVERNOR
requests: \(learning.totalAIRequests)
tokens: \(learning.totalTokens)
estimated spend: $\(String(format:"%.4f",learning.estimatedSpendUSD))

CAPABILITIES
\(capabilities.count) registered

RULE
Reuse verified local knowledge first. Purchase cloud intelligence only when uncertainty, novelty or risk requires escalation.
""");return}

        if let invocation=DeterministicCommandRouter.shared.invocation(for:trimmed,capabilities:capabilities),let capability=capabilities.first(where:{$0.id==invocation.capabilityId}){
            do{let outcome=try await capabilityRunner.run(capability:capability,invocation:invocation,context:.init(recentHistory:recentHistory));deliver(outcome)}catch{onAssistantMessage?("Σφάλμα local execution: \(error.localizedDescription)")};return
        }
        if let outcome=try? await sessionRecallService.evaluate(message,excluding:liveSessionId,recentHistory:recentHistory){switch outcome{case .found(let sessionId):onSessionRecall?(sessionId);return;case .notFound:onAssistantMessage?("Δεν βρήκα παλαιότερη συνομιλία που να ταιριάζει με αυτό που ζήτησες.");return;case .notRecall:break}}
        let keywordMatch=capabilities.first{c in !c.keywords.isEmpty && c.keywords.contains{lowered.contains($0.lowercased())}}
        let defaultCapability=capabilities.first{$0.keywords.isEmpty}
        var selectedCapability:AgentCapability?=keywordMatch
        if selectedCapability==nil {
            let allowed=Set(capabilities.map(\.id))
            if let learned=VerifiedRoutingMemory.shared.bestMatch(for:message,allowedCapabilityIds:allowed),let capability=capabilities.first(where:{$0.id==learned.capabilityId}) {
                selectedCapability=capability
                LocalIntelligenceMetrics.shared.record(.learnedCapabilityRoute)
            }
        }
        if selectedCapability==nil {selectedCapability=await CapabilitySelectionService().select(message:message,capabilities:capabilities,recentHistory:recentHistory) ?? defaultCapability}
        guard let capability=selectedCapability else{onAssistantMessage?("Δεν κατάλαβα ποια δραστηριότητα αφορά αυτό.");return}
        do{let outcome=try await capabilityRunner.run(capability:capability,command:message,context:.init(recentHistory:recentHistory));deliver(outcome)}catch{onAssistantMessage?("Σφάλμα: \(error.localizedDescription)")}
    }

    private func deliver(_ outcome:CapabilityOutcome){switch outcome{case .reply(let text):onAssistantMessage?(text);case .proposal(let action):approvalGate.submit(action);case .none:break}}
    private enum TaskResolution{case found(AgentTask),ambiguous([AgentTask]),notFound}
    private func persistedTasksNewestFirst()throws->[AgentTask]{try taskStore.load().sorted{$0.updatedAt>$1.updatedAt}}
    private func resolveTask(reference:String?)throws->TaskResolution{
        let tasks=try persistedTasksNewestFirst();guard !tasks.isEmpty else{return .notFound};guard let raw=reference?.trimmingCharacters(in:.whitespacesAndNewlines),!raw.isEmpty else{return .found(tasks[0])};let reference=raw.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"el_GR")).lowercased();if let exact=tasks.first(where:{$0.id.uuidString.lowercased()==reference}){return .found(exact)};let prefix=tasks.filter{$0.id.uuidString.lowercased().hasPrefix(reference)};if prefix.count==1{return .found(prefix[0])};if prefix.count>1{return .ambiguous(prefix)}
        let aliases:[String:AgentTaskStatus]=["failed":.failed,"αποτυχημενο":.failed,"αποτυχια":.failed,"completed":.completed,"ολοκληρωμενο":.completed,"running":.running,"ενεργο":.running,"τρεχει":.running,"paused":.paused,"παγωμενο":.paused,"σε παυση":.paused,"cancelled":.cancelled,"ακυρωμενο":.cancelled,"waitingforapproval":.waitingForApproval,"approval":.waitingForApproval]
        let normalizedStatus=AgentTaskStatus(rawValue:reference) ?? aliases[reference];if let s=normalizedStatus,let first=tasks.first(where:{$0.status==s}){return .found(first)}
        let stop:Set<String>=["task","το","του","τη","την","για","με","μου","ένα","ενα","status","log","δειξε","δείξε","show","previous","προηγουμενο","τελευταιο","latest"];let tokens=reference.split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{$0.count>=3 && !stop.contains($0)};guard !tokens.isEmpty else{return .notFound};let scored=tasks.compactMap{t->(AgentTask,Int)? in let searchable=(t.title+" "+t.goal).folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"el_GR")).lowercased(),score=tokens.reduce(0){$0+(searchable.contains($1) ? 1:0)};return score>0 ? (t,score):nil}.sorted{$0.1 != $1.1 ? $0.1>$1.1:$0.0.updatedAt>$1.0.updatedAt};guard let best=scored.first else{return .notFound};if scored.count>1,scored[1].1==best.1{return .ambiguous(scored.filter{$0.1==best.1}.map(\.0))};return .found(best.0)
    }
    private func renderTaskHistory()->String{do{let tasks=try persistedTasksNewestFirst();guard !tasks.isEmpty else{return"Δεν υπάρχει αποθηκευμένο autonomous task."};let rows=tasks.prefix(20).map{t in let total=t.plan.steps.count,completed=t.plan.steps.filter{$0.status == .completed || $0.status == .skipped}.count,progress=total>0 ? Int(Double(completed)/Double(total)*100):0;return"\(t.id.uuidString.prefix(8))  [\(t.status.rawValue)]  \(progress)%  v\(t.plan.version)  — \(t.title)"}.joined(separator:"\n");return"AUTONOMOUS TASK HISTORY\n\n\(rows)\n\nΧρήση:\n/task-status <ID ή λέξη από τίτλο>\n/task-log <ID ή λέξη από τίτλο>"}catch{return"Αποτυχία ανάγνωσης autonomous task history: \(error.localizedDescription)"}}
    private func renderTaskStatus(reference:String?)->String{do{switch try resolveTask(reference:reference){case .notFound:return"Δεν βρέθηκε autonomous task που να ταιριάζει με \(reference ?? "την επιλογή"). Χρησιμοποίησε /tasks για τη λίστα.";case .ambiguous(let tasks):return renderAmbiguousTaskSelection(tasks,command:"/task-status");case .found(let task):return renderStatus(for:task)}}catch{return"Αποτυχία ανάγνωσης autonomous task status: \(error.localizedDescription)"}}
    private func renderStatus(for task:AgentTask)->String{let total=task.plan.steps.count,completed=task.plan.steps.filter{$0.status == .completed || $0.status == .skipped}.count,progress=total>0 ? Int(Double(completed)/Double(total)*100):0,current=task.executionState.currentStepId.flatMap{id in task.plan.steps.first{$0.id==id}},completedIds=Set(task.plan.steps.filter{$0.status == .completed}.map(\.id)),next=task.plan.steps.sorted{$0.order<$1.order}.first{s in (s.status == .pending || s.status == .ready)&&s.dependencyStepIds.allSatisfy{completedIds.contains($0)}},runtime=task.budget.maxRuntimeSeconds.map{"\(Int($0))s"} ?? "unlimited",steps=task.budget.maxSteps.map(String.init) ?? "unlimited";return"""
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
\(progress)% (\(completed)/\(total) steps)
CURRENT / NEXT STEP
\(current.map{"#\($0.order) — \($0.title)"} ?? next.map{"#\($0.order) — \($0.title)"} ?? "κανένα")
TOTAL EXECUTION ATTEMPTS
\(task.plan.steps.reduce(0){$0+$1.attemptCount})
LAST CHECKPOINT
\(task.executionState.lastCheckpoint?.summary ?? "κανένα")
FAILURE / PAUSE DETAIL
\(task.failureReason ?? current?.lastError ?? "κανένα")
BUDGET
maxSteps: \(steps)
maxRuntime: \(runtime)
maxRetriesPerStep: \(task.budget.maxRetriesPerStep)
"""}
    private func renderTaskLog(reference:String?)->String{do{switch try resolveTask(reference:reference){case .notFound:return"Δεν βρέθηκε autonomous task που να ταιριάζει με \(reference ?? "την επιλογή"). Χρησιμοποίησε /tasks για τη λίστα.";case .ambiguous(let tasks):return renderAmbiguousTaskSelection(tasks,command:"/task-log");case .found(let task):let rows=task.events.map{"[\(ISO8601DateFormatter().string(from:$0.createdAt))] \($0.type.rawValue.uppercased()) — \($0.message)"}.joined(separator:"\n");return"AUTONOMOUS TASK LOG\n\nTASK\n\(task.id.uuidString)\n\nSTATUS\n\(task.status.rawValue)\n\nEVENTS\n\(rows.isEmpty ? "κανένα":rows)"}}catch{return"Αποτυχία ανάγνωσης autonomous task log: \(error.localizedDescription)"}}
    private func renderAmbiguousTaskSelection(_ tasks:[AgentTask],command:String)->String{let rows=tasks.prefix(8).map{"\($0.id.uuidString.prefix(8)) — [\($0.status.rawValue)] \($0.title)"}.joined(separator:"\n");return"Βρήκα περισσότερα από ένα tasks που ταιριάζουν. Διάλεξε ID:\n\n\(rows)\n\n\(command) <ID>"}
}
