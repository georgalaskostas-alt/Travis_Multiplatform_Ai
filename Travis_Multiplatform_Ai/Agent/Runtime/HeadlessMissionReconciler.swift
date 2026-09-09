import Foundation

/// Reconciles worker-owned headless jobs back into their original Mission V2 tasks.
/// Idempotent: terminal task states are never rewritten and completed step order is monotonic.
@MainActor
enum HeadlessMissionReconciler {
    struct WorkerStep: Codable { var order:Int;var title:String?;var capability:String?;var status:String?;var result:JSONValue? }
    enum JSONValue:Codable { case string(String),number(Double),bool(Bool),object([String:JSONValue]),array([JSONValue]),null
        init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if c.decodeNil(){self = .null}else if let v=try? c.decode(Bool.self){self = .bool(v)}else if let v=try? c.decode(Double.self){self = .number(v)}else if let v=try? c.decode(String.self){self = .string(v)}else if let v=try? c.decode([String:JSONValue].self){self = .object(v)}else{self = .array(try c.decode([JSONValue].self))}}
        func encode(to encoder:Encoder)throws{var c=encoder.singleValueContainer();switch self{case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .null:try c.encodeNil()}}
        var compact:String{switch self{case .string(let v):return v;case .number(let v):return String(v);case .bool(let v):return String(v);case .null:return "null";case .array(let a):return "["+a.map(\.compact).joined(separator:", ")+"]";case .object(let o):return o.sorted{$0.key<$1.key}.map{"\($0.key): \($0.value.compact)"}.joined(separator:"; ")}}
    }
    struct WorkerResult:Codable { var summary:String?;var finalReport:String?;var steps:[WorkerStep]?;var completedSteps:Int?;var totalSteps:Int? }
    struct WorkerPayload:Codable { var sourceTaskID:String?;var sourcePlanVersion:Int?;var executionMode:String? }
    struct WorkerJob:Codable { var id:String;var kind:String;var state:String;var enabled:Bool?;var payload:WorkerPayload?;var lastResult:WorkerResult?;var lastError:String?;var updatedAt:TimeInterval? }
    struct Document:Codable { var version:Int?;var jobs:[WorkerJob] }

    static func reconcile(runtime:AgentTaskRuntime)->Int {
        guard let doc=load() else{return 0};var changed=0
        for job in doc.jobs where job.kind=="headlessMission" {
            guard let raw=job.payload?.sourceTaskID,let taskID=UUID(uuidString:raw),let task=runtime.task(id:taskID) else{continue}
            guard ![AgentTaskStatus.completed,.cancelled,.failed].contains(task.status) else{continue}
            if let version=job.payload?.sourcePlanVersion,version != task.plan.version{continue}
            let workerSteps=job.lastResult?.steps ?? []
            for ws in workerSteps where (ws.status ?? "completed")=="completed" {
                guard let step=task.plan.steps.first(where:{$0.order==ws.order}),step.status != .completed else{continue}
                runtime.markStepCompleted(taskId:taskID,stepId:step.id,resultSummary:ws.result.map{String($0.compact.prefix(6000))} ?? "Completed by Always-On worker")
                changed += 1
            }
            let state=job.state.lowercased()
            if state=="failed" { runtime.failTask(taskId:taskID,reason:"Always-On worker failed: \(job.lastError ?? "Unknown headless error")");changed += 1;continue }
            if state=="stopped",let result=job.lastResult {
                if let report=result.finalReport,!report.isEmpty { runtime.checkpoint(taskId:taskID,summary:"HEADLESS FINAL REPORT\n\(String(report.prefix(8000)))",nextAction:nil) }
                // mark any exported-but-unreported remaining steps completed only when worker explicitly reports all steps complete
                if let done=result.completedSteps,let total=result.totalSteps,done==total {
                    let remaining=runtime.task(id:taskID)?.plan.steps.filter{![.completed,.skipped].contains($0.status)} ?? []
                    for step in remaining { runtime.markStepCompleted(taskId:taskID,stepId:step.id,resultSummary:result.finalReport ?? result.summary ?? "Completed by Always-On worker");changed += 1 }
                }
            }
        }
        return changed
    }
    private static func load()->Document?{let fm=FileManager.default;guard let base=try? fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)else{return nil};let url=base.appendingPathComponent("TRAVIS/AlwaysOn/service-jobs-v1.json");guard let data=try? Data(contentsOf:url)else{return nil};return try? JSONDecoder().decode(Document.self,from:data)}
}
