import Foundation

@MainActor
enum HeadlessMissionReconciler {
    struct WorkerStep:Codable{var order:Int;var sourceStepID:String?;var title:String?;var capability:String?;var status:String?;var result:JSONValue?}
    struct MissionState:Codable{var completedSteps:[WorkerStep]?;var totalSteps:Int?}
    enum JSONValue:Codable{case string(String),number(Double),bool(Bool),object([String:JSONValue]),array([JSONValue]),null
        init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if c.decodeNil(){self = .null}else if let v=try? c.decode(Bool.self){self = .bool(v)}else if let v=try? c.decode(Double.self){self = .number(v)}else if let v=try? c.decode(String.self){self = .string(v)}else if let v=try? c.decode([String:JSONValue].self){self = .object(v)}else{self = .array(try c.decode([JSONValue].self))}}
        func encode(to encoder:Encoder)throws{var c=encoder.singleValueContainer();switch self{case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .null:try c.encodeNil()}}
        var compact:String{switch self{case .string(let v):return v;case .number(let v):return String(v);case .bool(let v):return String(v);case .null:return"null";case .array(let a):return"["+a.map(\.compact).joined(separator:", ")+"]";case .object(let o):return o.sorted{$0.key<$1.key}.map{"\($0.key): \($0.value.compact)"}.joined(separator:"; ")}}
    }
    struct WorkerResult:Codable{var summary:String?;var finalReport:String?;var steps:[WorkerStep]?;var completedSteps:Int?;var totalSteps:Int?}
    struct WorkerPayload:Codable{var sourceTaskID:String?;var sourcePlanVersion:Int?;var executionMode:String?;var plan:[WorkerPlanStep]?}
    struct WorkerPlanStep:Codable{var order:Int;var sourceStepID:String?}
    struct WorkerJob:Codable{var id:String;var kind:String;var state:String;var enabled:Bool?;var payload:WorkerPayload?;var missionState:MissionState?;var lastResult:WorkerResult?;var lastError:String?;var updatedAt:TimeInterval?}
    struct Document:Codable{var version:Int?;var jobs:[WorkerJob]}

    static func reconcile(runtime:AgentTaskRuntime)->Int{
        guard let doc=load()else{return 0};var changed=0
        for job in doc.jobs where job.kind=="headlessMission"{
            guard let raw=job.payload?.sourceTaskID,let taskID=UUID(uuidString:raw),let original=runtime.task(id:taskID)else{continue}
            guard ![AgentTaskStatus.completed,.cancelled].contains(original.status)else{continue}
            if let v=job.payload?.sourcePlanVersion,v != original.plan.version{continue}
            let state=job.state.lowercased()
            if original.status == .failed {
                let workerFailure = original.failureReason?.hasPrefix("Always-On worker failed:") == true
                guard workerFailure else{continue}
                if state == "failed" { continue }
                // A worker retry owns execution. Reattach the exact same plan to clear terminal GUI failure
                // without replanning, then immediately return it to paused/headless ownership.
                runtime.attachPlan(taskId:taskID,plan:original.plan);runtime.start(taskId:taskID);runtime.pause(taskId:taskID,reason:"ALWAYS-ON HEADLESS retry ownership · worker job \(job.id)");changed += 1
            }
            let exportedIDs=Set((job.payload?.plan ?? []).compactMap{$0.sourceStepID}.compactMap(UUID.init(uuidString:)))
            let evidence=(job.lastResult?.steps ?? job.missionState?.completedSteps ?? [])
            for ws in evidence where (ws.status ?? "completed")=="completed"{
                let step:PlanStep?
                if let sid=ws.sourceStepID.flatMap(UUID.init(uuidString:)){step=runtime.task(id:taskID)?.plan.steps.first{$0.id==sid}}
                else{step=runtime.task(id:taskID)?.plan.steps.first{$0.order==ws.order && (exportedIDs.isEmpty || exportedIDs.contains($0.id))}}
                guard let step,step.status != .completed else{continue}
                runtime.markStepCompleted(taskId:taskID,stepId:step.id,resultSummary:ws.result.map{String($0.compact.prefix(6000))} ?? "Completed by Always-On worker");changed += 1
                if let current=runtime.task(id:taskID),current.status == .running { runtime.pause(taskId:taskID,reason:"ALWAYS-ON HEADLESS ownership · worker job \(job.id)") }
            }
            if state=="failed"{runtime.failTask(taskId:taskID,reason:"Always-On worker failed: \(job.lastError ?? "Unknown headless error")");changed += 1;continue}
            if ["running","scheduled","sleeping","paused"].contains(state){runtime.checkpoint(taskId:taskID,summary:"ALWAYS-ON HEADLESS · \(evidence.count)/\((job.payload?.plan ?? []).count) exported steps · \(state.uppercased())",nextAction:nil)}
            if state=="stopped",let result=job.lastResult{
                if let report=result.finalReport,!report.isEmpty{runtime.checkpoint(taskId:taskID,summary:"HEADLESS FINAL REPORT\n\(String(report.prefix(8000)))",nextAction:nil)}
                if let done=result.completedSteps,let total=result.totalSteps,done==total{
                    let current=runtime.task(id:taskID)
                    for step in current?.plan.steps ?? [] where exportedIDs.contains(step.id) && step.status != .completed && step.status != .skipped{runtime.markStepCompleted(taskId:taskID,stepId:step.id,resultSummary:result.finalReport ?? result.summary ?? "Completed by Always-On worker");changed += 1}
                    if let current=runtime.task(id:taskID),current.status == .running{runtime.pause(taskId:taskID,reason:"Headless reconciliation completed exported subset; foreground ownership requires explicit resume")}
                }
            }
        }
        return changed
    }
    private static func load()->Document?{let fm=FileManager.default;guard let base=try? fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)else{return nil};let url=base.appendingPathComponent("TRAVIS/AlwaysOn/service-jobs-v1.json");guard let data=try? Data(contentsOf:url)else{return nil};return try? JSONDecoder().decode(Document.self,from:data)}
}
