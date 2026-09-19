import Foundation

@MainActor enum HeadlessMissionHandoff {
    struct ExportResult:Equatable { let jobID:UUID;let exportedSteps:Int;let mode:String }
    struct Analysis:Equatable { let headlessStepIDs:Set<UUID>;let foregroundStepIDs:Set<UUID>;var isFullyHeadless:Bool{!headlessStepIDs.isEmpty && foregroundStepIDs.isEmpty};var isHybrid:Bool{!headlessStepIDs.isEmpty && !foregroundStepIDs.isEmpty} }
    enum HandoffError:LocalizedError { case noSteps,unsupportedStep(String),approvalRequired(String),foregroundOnly(String),missingArguments(String),workerUnavailable,writeFailed(String);var errorDescription:String?{switch self{case .noSteps:return "Mission has no executable headless steps.";case .unsupportedStep(let v):return "Step cannot run headlessly: \(v)";case .approvalRequired(let v):return "Approval-gated step stays in GUI runtime: \(v)";case .foregroundOnly(let v):return "Foreground-only step stays in GUI runtime: \(v)";case .missingArguments(let v):return "Headless step is missing deterministic arguments: \(v)";case .workerUnavailable:return "Headless worker is offline.";case .writeFailed(let v):return "Headless handoff failed: \(v)"}}}

    static func analyze(task:AgentTask)->Analysis {
        let remaining=task.plan.steps.filter{$0.status != .completed && $0.status != .skipped};var headless=Set<UUID>();var foreground=Set<UUID>()
        for step in remaining {
            let mapped=mappedCapability(step.capabilityId);let args=mapped.flatMap{arguments(for:step,capability:$0)};let needsArgs=mapped.map{["repository.snapshot","filesystem.inventory","network.http_probe","market.analyze","repository.audit","ai.reason"].contains($0)} ?? false
            let safe=step.canRunInBackground && !step.requiresApproval && mapped != nil && (!needsArgs || args != nil)
            if safe { headless.insert(step.id) } else { foreground.insert(step.id) }
        }
        var changed=true
        while changed { changed=false;for step in remaining where headless.contains(step.id) { if step.dependencyStepIds.contains(where:{foreground.contains($0)}) { headless.remove(step.id);foreground.insert(step.id);changed=true } } }
        return Analysis(headlessStepIDs:headless,foregroundStepIDs:foreground)
    }
    static func eligibility(task:AgentTask)->Result<[String],HandoffError>{let a=analyze(task:task);guard a.isFullyHeadless else{return .failure(.foregroundOnly("plan contains foreground or dependency-bound steps"))};return .success(task.plan.steps.filter{a.headlessStepIDs.contains($0.id)}.compactMap{mappedCapability($0.capabilityId)})}
    static func export(task:AgentTask,allowHybrid:Bool=true,requireHealthyWorker:Bool=true)throws->ExportResult{
        let monitor=AlwaysOnWorkerMonitor.shared
        if requireHealthyWorker {monitor.refresh();guard monitor.isHealthy else{throw HandoffError.workerUnavailable}}
        let analysis=analyze(task:task);guard !analysis.headlessStepIDs.isEmpty else{throw HandoffError.noSteps};if !allowHybrid && !analysis.isFullyHeadless{throw HandoffError.foregroundOnly("hybrid export disabled")}
        let selected=task.plan.steps.sorted{$0.order<$1.order}.filter{analysis.headlessStepIDs.contains($0.id)};var plan:[[String:Any]]=[]
        for step in selected {
            guard let cap=mappedCapability(step.capabilityId)else{throw HandoffError.unsupportedStep(step.capabilityId ?? step.title)}
            let args=arguments(for:step,capability:cap)
            if ["repository.snapshot","filesystem.inventory","network.http_probe","market.analyze","repository.audit","ai.reason"].contains(cap),args==nil{throw HandoffError.missingArguments(step.title)}
            var item:[String:Any]=["order":step.order,"sourceStepID":step.id.uuidString,"title":step.title,"capability":cap]
            if let args{item["arguments"]=args};plan.append(item)
        }
        let id=UUID(),mode=analysis.isFullyHeadless ? "full":"hybrid"
        let payload:[String:Any]=["goal":task.goal,"sourceTaskID":task.id.uuidString,"sourcePlanVersion":task.plan.version,"executionMode":mode,"plan":plan]
        do{try monitor.enqueueCreateJob(id:id,title:"Mission V2 · \(task.title)",kind:"headlessMission",payload:payload)}catch{throw HandoffError.writeFailed(error.localizedDescription)}
        return .init(jobID:id,exportedSteps:plan.count,mode:mode)
    }
    private static func mappedCapability(_ id:String?)->String?{switch id{case "repository_context":return "repository.snapshot";case "runtime_health","system_scan":return "runtime.health";case "runtime_identity":return "runtime.identity";case "runtime_safety":return "runtime.safety";case "filesystem_inventory":return "filesystem.inventory";case "http_probe","network_probe":return "network.http_probe";case "report_synthesis":return "report.synthesize";case "market_intelligence":return "market.analyze";case "self_audit":return "repository.audit";case "headless_reasoning":return "ai.reason";default:return nil}}
    private static func arguments(for step:PlanStep,capability:String)->[String:String]?{
        let text=step.instructions.trimmingCharacters(in:.whitespacesAndNewlines)
        if capability=="repository.snapshot" || capability=="filesystem.inventory" || capability=="repository.audit"{guard let p=firstValue(prefixes:["path=","repoPath=","rootPath="],in:text)else{return nil};return ["path":p]}
        if capability=="network.http_probe"{guard let u=firstValue(prefixes:["url="],in:text)else{return nil};return ["url":u]}
        if capability=="market.analyze"{guard let asset=firstValue(prefixes:["asset="],in:text)else{return nil};var r=["asset":asset];if let interval=firstValue(prefixes:["interval="],in:text){r["interval"]=interval};return r}
        if capability=="ai.reason"{guard !text.isEmpty else{return nil};return ["prompt":text,"maxTokens":"2200"]}
        return nil
    }
    private static func firstValue(prefixes:[String],in text:String)->String?{for token in text.split(whereSeparator:{$0.isWhitespace || $0=="," || $0==";"}){let value=String(token);for prefix in prefixes where value.hasPrefix(prefix){let r=String(value.dropFirst(prefix.count)).trimmingCharacters(in:CharacterSet(charactersIn:"\"'"));if !r.isEmpty{return r}}};return nil}
}
