import Foundation

@MainActor enum HeadlessMissionHandoff {
    struct ExportResult:Equatable { let jobID:UUID;let exportedSteps:Int;let mode:String }
    struct Analysis:Equatable { let headlessStepIDs:Set<UUID>;let foregroundStepIDs:Set<UUID>;var isFullyHeadless:Bool{!headlessStepIDs.isEmpty && foregroundStepIDs.isEmpty};var isHybrid:Bool{!headlessStepIDs.isEmpty && !foregroundStepIDs.isEmpty} }
    enum HandoffError:LocalizedError { case noSteps,unsupportedStep(String),approvalRequired(String),foregroundOnly(String),missingArguments(String),workerUnavailable,writeFailed(String);var errorDescription:String?{switch self{case .noSteps:return "Mission has no executable headless steps.";case .unsupportedStep(let v):return "Step cannot run headlessly: \(v)";case .approvalRequired(let v):return "Approval-gated step stays in GUI runtime: \(v)";case .foregroundOnly(let v):return "Foreground-only step stays in GUI runtime: \(v)";case .missingArguments(let v):return "Headless step is missing deterministic arguments: \(v)";case .workerUnavailable:return "Headless worker is offline.";case .writeFailed(let v):return "Headless handoff failed: \(v)"}}}
    private struct ServiceDocument:Codable { var version:Int;var jobs:[ServiceJob] }
    private struct ServiceJob:Codable { var id:String;var title:String;var kind:String;var state:String;var createdAt:TimeInterval;var updatedAt:TimeInterval;var nextRunAt:TimeInterval?;var cadenceSeconds:Double?;var payload:Payload;var enabled:Bool;var failures:Int;var recoveryCount:Int;var lastError:String?;var lease:String?;var checkpoint:String? }
    private struct Payload:Codable { var goal:String;var sourceTaskID:String;var sourcePlanVersion:Int;var executionMode:String;var plan:[HeadlessStep] }
    private struct HeadlessStep:Codable { var order:Int;var title:String;var capability:String;var arguments:[String:String]? }

    static func analyze(task:AgentTask)->Analysis {
        let remaining=task.plan.steps.filter{$0.status != .completed && $0.status != .skipped};var headless=Set<UUID>();var foreground=Set<UUID>()
        for step in remaining {
            let mapped=mappedCapability(step.capabilityId);let args=mapped.flatMap{arguments(for:step,capability:$0)};let needsArgs=mapped.map{["repository.snapshot","filesystem.inventory","network.http_probe"].contains($0)} ?? false
            let safe=step.canRunInBackground && !step.requiresApproval && mapped != nil && (!needsArgs || args != nil)
            if safe { headless.insert(step.id) } else { foreground.insert(step.id) }
        }
        // A headless step may not depend on an unfinished foreground step. Keep such dependent work foreground.
        var changed=true
        while changed { changed=false;for step in remaining where headless.contains(step.id) { if step.dependencyStepIds.contains(where:{foreground.contains($0)}) { headless.remove(step.id);foreground.insert(step.id);changed=true } } }
        return Analysis(headlessStepIDs:headless,foregroundStepIDs:foreground)
    }
    static func eligibility(task:AgentTask)->Result<[String],HandoffError>{let a=analyze(task:task);guard a.isFullyHeadless else{return .failure(.foregroundOnly("plan contains foreground or dependency-bound steps"))};return .success(task.plan.steps.filter{a.headlessStepIDs.contains($0.id)}.compactMap{mappedCapability($0.capabilityId)})}
    static func export(task:AgentTask,allowHybrid:Bool=true,requireHealthyWorker:Bool=true)throws->ExportResult{
        if requireHealthyWorker {AlwaysOnWorkerMonitor.shared.refresh();guard AlwaysOnWorkerMonitor.shared.isHealthy else{throw HandoffError.workerUnavailable}}
        let analysis=analyze(task:task);guard !analysis.headlessStepIDs.isEmpty else{throw HandoffError.noSteps};if !allowHybrid && !analysis.isFullyHeadless{throw HandoffError.foregroundOnly("hybrid export disabled")}
        let selected=task.plan.steps.sorted{$0.order<$1.order}.filter{analysis.headlessStepIDs.contains($0.id)};var steps:[HeadlessStep]=[]
        for step in selected {guard let cap=mappedCapability(step.capabilityId)else{throw HandoffError.unsupportedStep(step.capabilityId ?? step.title)};let args=arguments(for:step,capability:cap);if ["repository.snapshot","filesystem.inventory","network.http_probe"].contains(cap),args==nil{throw HandoffError.missingArguments(step.title)};steps.append(.init(order:step.order,title:step.title,capability:cap,arguments:args))}
        let id=UUID(),now=Date().timeIntervalSince1970,mode=analysis.isFullyHeadless ? "full":"hybrid"
        let job=ServiceJob(id:id.uuidString,title:"Mission V2 · \(task.title)",kind:"headlessMission",state:"scheduled",createdAt:now,updatedAt:now,nextRunAt:now,cadenceSeconds:nil,payload:.init(goal:task.goal,sourceTaskID:task.id.uuidString,sourcePlanVersion:task.plan.version,executionMode:mode,plan:steps),enabled:true,failures:0,recoveryCount:0,lastError:nil,lease:nil,checkpoint:nil)
        do{try append(job:job)}catch{throw HandoffError.writeFailed(error.localizedDescription)};return .init(jobID:id,exportedSteps:steps.count,mode:mode)
    }
    private static func mappedCapability(_ id:String?)->String?{switch id{case "repository_context":return "repository.snapshot";case "runtime_health","system_scan":return "runtime.health";case "runtime_identity":return "runtime.identity";case "runtime_safety":return "runtime.safety";case "filesystem_inventory":return "filesystem.inventory";case "http_probe","network_probe":return "network.http_probe";case "report_synthesis":return "report.synthesize";default:return nil}}
    private static func arguments(for step:PlanStep,capability:String)->[String:String]?{let text=step.instructions;if capability=="repository.snapshot" || capability=="filesystem.inventory"{guard let p=firstValue(prefixes:["path=","repoPath=","rootPath="],in:text)else{return nil};return ["path":p]};if capability=="network.http_probe"{guard let u=firstValue(prefixes:["url="],in:text)else{return nil};return ["url":u]};return nil}
    private static func firstValue(prefixes:[String],in text:String)->String?{for token in text.split(whereSeparator:{$0.isWhitespace || $0=="," || $0==";"}){let value=String(token);for prefix in prefixes where value.hasPrefix(prefix){let r=String(value.dropFirst(prefix.count)).trimmingCharacters(in:CharacterSet(charactersIn:"\"'"));if !r.isEmpty{return r}}};return nil}
    private static func append(job:ServiceJob)throws{let fm=FileManager.default;let base=try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true);let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true);try fm.createDirectory(at:dir,withIntermediateDirectories:true);let url=dir.appendingPathComponent("service-jobs-v1.json");var doc:ServiceDocument;if let data=try? Data(contentsOf:url),let decoded=try? JSONDecoder().decode(ServiceDocument.self,from:data){doc=decoded}else{doc=.init(version:5,jobs:[])};doc.version=5;doc.jobs.append(job);try JSONEncoder().encode(doc).write(to:url,options:.atomic)}
}
