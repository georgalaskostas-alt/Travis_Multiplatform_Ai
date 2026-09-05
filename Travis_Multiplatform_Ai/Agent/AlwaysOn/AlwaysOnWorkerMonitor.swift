import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnWorkerMonitor {
    static let shared = AlwaysOnWorkerMonitor()
    struct ServiceJob: Codable, Equatable, Identifiable {
        var id:UUID;var title:String;var kind:String;var state:String;var nextRunAt:TimeInterval?;var failures:Int;var lastError:String?;var enabled:Bool;var lastCompletedAt:TimeInterval?;var summary:String?;var finalReport:String?
    }
    struct Snapshot: Codable, Equatable {
        var version:Int;var generation:String?;var pid:Int32;var startedAt:TimeInterval;var lastBeatAt:TimeInterval;var killSwitch:Bool;var state:String;var activeServiceJobs:Int?;var failedServiceJobs:Int?;var serviceJobs:[ServiceJob]?
    }
    private(set) var snapshot:Snapshot?
    private(set) var isHealthy=false
    private var task:Task<Void,Never>?
    private let heartbeatURL:URL
    private let controlURL:URL
    private let commandURL:URL
    var serviceJobs:[ServiceJob]{snapshot?.serviceJobs ?? []}

    init(fileManager:FileManager = .default){let base=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fileManager.temporaryDirectory;let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true);try? fileManager.createDirectory(at:dir,withIntermediateDirectories:true);heartbeatURL=dir.appendingPathComponent("worker-heartbeat.json");controlURL=dir.appendingPathComponent("worker-control.json");commandURL=dir.appendingPathComponent("worker-command.json")}
    func start(){guard task==nil else{return};task=Task{[weak self] in while !Task.isCancelled{self?.refresh();try? await Task.sleep(for:.seconds(2))}}}
    func stop(){task?.cancel();task=nil}
    func refresh(){guard let data=try? Data(contentsOf:heartbeatURL),let value=try? JSONDecoder().decode(Snapshot.self,from:data) else{snapshot=nil;isHealthy=false;return};snapshot=value;isHealthy=Date().timeIntervalSince1970-value.lastBeatAt < 8}
    func setKillSwitch(_ enabled:Bool)throws{let payload=["killSwitch":enabled];let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);try data.write(to:controlURL,options:.atomic);refresh()}
    func sendServiceJobCommand(action:String,jobID:UUID)throws{let payload:[String:Any]=["action":action,"jobID":jobID.uuidString,"nonce":UUID().uuidString,"createdAt":Date().timeIntervalSince1970];let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);try data.write(to:commandURL,options:.atomic)}
    func resolveServiceJob(_ raw:String)->ServiceJob?{let key=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if let id=UUID(uuidString:key){return serviceJobs.first{$0.id==id}};let matches=serviceJobs.filter{$0.id.uuidString.lowercased().hasPrefix(key)};return matches.count==1 ? matches[0]:nil}
}
