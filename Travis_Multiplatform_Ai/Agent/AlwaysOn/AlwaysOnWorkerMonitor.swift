import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnWorkerMonitor {
    static let shared = AlwaysOnWorkerMonitor()
    struct Snapshot: Codable, Equatable { var version:Int; var pid:Int32; var startedAt:TimeInterval; var lastBeatAt:TimeInterval; var killSwitch:Bool; var state:String }
    private(set) var snapshot:Snapshot?
    private(set) var isHealthy=false
    private var task:Task<Void,Never>?
    private let heartbeatURL:URL
    private let controlURL:URL

    init(fileManager:FileManager = .default){
        let base=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fileManager.temporaryDirectory
        let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true);try? fileManager.createDirectory(at:dir,withIntermediateDirectories:true)
        heartbeatURL=dir.appendingPathComponent("worker-heartbeat.json");controlURL=dir.appendingPathComponent("worker-control.json")
    }
    func start(){guard task==nil else{return};task=Task{[weak self] in while !Task.isCancelled { self?.refresh();try? await Task.sleep(for:.seconds(2)) }}}
    func stop(){task?.cancel();task=nil}
    func refresh(){guard let data=try? Data(contentsOf:heartbeatURL),let value=try? JSONDecoder().decode(Snapshot.self,from:data) else{snapshot=nil;isHealthy=false;return};snapshot=value;isHealthy=Date().timeIntervalSince1970-value.lastBeatAt < 8}
    func setKillSwitch(_ enabled:Bool) throws { let payload=["killSwitch":enabled];let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);try data.write(to:controlURL,options:.atomic);refresh() }
}
