import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnWorkerMonitor {
    static let shared = AlwaysOnWorkerMonitor()
    struct Checkpoint: Codable, Equatable { var order:Int?;var title:String?;var capability:String?;var status:String?;var at:TimeInterval? }
    struct ServiceJob: Codable, Equatable, Identifiable {
        var id:UUID;var title:String;var kind:String;var state:String;var nextRunAt:TimeInterval?;var failures:Int;var recoveryCount:Int?;var lastError:String?;var enabled:Bool;var lastCompletedAt:TimeInterval?;var summary:String?;var finalReport:String?;var completedSteps:Int?;var totalSteps:Int?;var checkpoint:Checkpoint?
        var progress:Double{guard let total=totalSteps,total>0 else{return state=="stopped" ? 1:0};return min(1,max(0,Double(completedSteps ?? 0)/Double(total)))}
    }
    struct Snapshot: Codable, Equatable { var version:Int;var generation:String?;var pid:Int32;var startedAt:TimeInterval;var lastBeatAt:TimeInterval;var killSwitch:Bool;var state:String;var activeServiceJobs:Int?;var failedServiceJobs:Int?;var serviceJobs:[ServiceJob]? }
    private(set) var snapshot:Snapshot?;private(set) var isHealthy=false;private var task:Task<Void,Never>?
    private let heartbeatURL:URL,controlURL:URL,legacyCommandURL:URL,commandQueueURL:URL
    var serviceJobs:[ServiceJob]{snapshot?.serviceJobs ?? []};var heartbeatAge:TimeInterval?{snapshot.map{Date().timeIntervalSince1970-$0.lastBeatAt}}
    init(fileManager:FileManager = .default){let base=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fileManager.temporaryDirectory;let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true);try? fileManager.createDirectory(at:dir,withIntermediateDirectories:true);heartbeatURL=dir.appendingPathComponent("worker-heartbeat.json");controlURL=dir.appendingPathComponent("worker-control.json");legacyCommandURL=dir.appendingPathComponent("worker-command.json");commandQueueURL=dir.appendingPathComponent("worker-command-queue.json")}
    func start(){guard task==nil else{return};task=Task{[weak self] in while !Task.isCancelled{self?.refresh();try? await Task.sleep(for:.seconds(2))}}}
    func stop(){task?.cancel();task=nil}
    func refresh(){guard let data=try? Data(contentsOf:heartbeatURL),let value=try? JSONDecoder().decode(Snapshot.self,from:data) else{snapshot=nil;isHealthy=false;return};snapshot=value;isHealthy=Date().timeIntervalSince1970-value.lastBeatAt < 8}
    func setKillSwitch(_ enabled:Bool)throws{let payload=["killSwitch":enabled];let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);try data.write(to:controlURL,options:.atomic);refresh()}
    func sendServiceJobCommand(action:String,jobID:UUID)throws{
        let normalized=action.lowercased(),allowed:Set<String>=["pause","resume","retry","delete"];guard allowed.contains(normalized) else{throw WorkerCommandError.unsupported}
        let command:[String:Any]=["action":normalized,"jobID":jobID.uuidString,"nonce":UUID().uuidString,"createdAt":Date().timeIntervalSince1970]
        try enqueue(command)
        // Compatibility transport for pre-v8 workers only. New workers consume the queue.
        if (snapshot?.version ?? 0) < 8 { let legacyData=try JSONSerialization.data(withJSONObject:command,options:[.sortedKeys]);try legacyData.write(to:legacyCommandURL,options:.atomic) }
    }
    /// Creates a worker-owned job without ever decoding or rewriting service-jobs-v1.json from Swift.
    /// Job validation, locking and duplicate protection are owned by the worker process.
    func enqueueCreateJob(id:UUID,title:String,kind:String,payload:[String:Any],cadenceSeconds:Double?=nil)throws{
        var job:[String:Any]=["id":id.uuidString,"title":title,"kind":kind,"state":"scheduled","createdAt":Date().timeIntervalSince1970,"updatedAt":Date().timeIntervalSince1970,"nextRunAt":Date().timeIntervalSince1970,"payload":payload,"enabled":true,"failures":0,"recoveryCount":0]
        if let cadenceSeconds { job["cadenceSeconds"]=cadenceSeconds }
        try enqueue(["action":"create","job":job,"nonce":UUID().uuidString,"createdAt":Date().timeIntervalSince1970])
    }
    private func enqueue(_ command:[String:Any])throws{
        var queue:[[String:Any]]=[]
        if let data=try? Data(contentsOf:commandQueueURL),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let existing=object["commands"] as? [[String:Any]]{queue=existing}
        queue.append(command);if queue.count>500{throw WorkerCommandError.queueFull}
        let data=try JSONSerialization.data(withJSONObject:["version":2,"commands":queue],options:[.sortedKeys]);try data.write(to:commandQueueURL,options:.atomic)
    }
    func resolveServiceJob(_ raw:String)->ServiceJob?{let key=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if let id=UUID(uuidString:key){return serviceJobs.first{$0.id==id}};let matches=serviceJobs.filter{$0.id.uuidString.lowercased().hasPrefix(key)};return matches.count==1 ? matches[0]:nil}
    enum WorkerCommandError:LocalizedError{case unsupported,queueFull;var errorDescription:String?{switch self{case .unsupported:return "Unsupported worker command";case .queueFull:return "Worker command queue is full"}}}
}
