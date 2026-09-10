import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnWorkerMonitor {
    static let shared = AlwaysOnWorkerMonitor()
    struct Checkpoint:Codable,Equatable{var order:Int?;var title:String?;var capability:String?;var status:String?;var at:TimeInterval?}
    struct MarketAsset:Codable,Equatable{var asset:String;var price:Double;var signal:String;var confidence:Double;var trendScore:Double;var rsi14:Double?;var change24hPercent:Double?;var regime:String?}
    struct MarketReport:Codable,Equatable{var generatedAt:TimeInterval?;var interval:String?;var assets:[MarketAsset]?}
    struct PortfolioReport:Codable,Equatable{var cash:Double?;var equity:Double?;var unrealizedPnL:Double?;var realizedPnL:Double?;var dailyRealizedPnL:Double?;var openPositions:Int?;var closedTrades:Int?;var wins:Int?;var losses:Int?;var winRate:Double?;var profitFactor:Double?;var drawdownPercent:Double?}
    struct TradingAction:Codable,Equatable{var action:String?;var asset:String?;var price:Double?;var qty:Double?;var pnl:Double?;var reason:String?;var stop:Double?;var take:Double?}
    struct AuditCounts:Codable,Equatable{var high:Int?;var medium:Int?;var low:Int?}
    struct AuditReport:Codable,Equatable{var path:String?;var scannedFiles:Int?;var counts:AuditCounts?;var note:String?}
    struct ServiceJob:Codable,Equatable,Identifiable{
        var id:UUID;var title:String;var kind:String;var state:String;var nextRunAt:TimeInterval?;var failures:Int;var recoveryCount:Int?;var lastError:String?;var enabled:Bool;var lastCompletedAt:TimeInterval?;var summary:String?;var finalReport:String?;var completedSteps:Int?;var totalSteps:Int?;var checkpoint:Checkpoint?;var portfolio:PortfolioReport?;var market:MarketReport?;var actions:[TradingAction]?;var audit:AuditReport?
        var progress:Double{guard let total=totalSteps,total>0 else{return state=="stopped" ? 1:0};return min(1,max(0,Double(completedSteps ?? 0)/Double(total)))}
    }
    struct Snapshot:Codable,Equatable{var version:Int;var generation:String?;var pid:Int32;var startedAt:TimeInterval;var lastBeatAt:TimeInterval;var killSwitch:Bool;var state:String;var activeServiceJobs:Int?;var failedServiceJobs:Int?;var marketEngine:Bool?;var serviceJobs:[ServiceJob]?}
    private(set)var snapshot:Snapshot?;private(set)var isHealthy=false;private var task:Task<Void,Never>?
    private let heartbeatURL:URL,controlURL:URL,legacyCommandURL:URL,commandQueueURL:URL
    var serviceJobs:[ServiceJob]{snapshot?.serviceJobs ?? []};var heartbeatAge:TimeInterval?{snapshot.map{Date().timeIntervalSince1970-$0.lastBeatAt}}
    init(fileManager:FileManager = .default){let base=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fileManager.temporaryDirectory;let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true);try? fileManager.createDirectory(at:dir,withIntermediateDirectories:true);heartbeatURL=dir.appendingPathComponent("worker-heartbeat.json");controlURL=dir.appendingPathComponent("worker-control.json");legacyCommandURL=dir.appendingPathComponent("worker-command.json");commandQueueURL=dir.appendingPathComponent("worker-command-queue.json")}
    func start(){guard task==nil else{return};task=Task{[weak self] in while !Task.isCancelled{self?.refresh();try? await Task.sleep(for:.seconds(2))}}}
    func stop(){task?.cancel();task=nil}
    func refresh(){guard let data=try? Data(contentsOf:heartbeatURL),let value=try? JSONDecoder().decode(Snapshot.self,from:data)else{snapshot=nil;isHealthy=false;return};snapshot=value;isHealthy=Date().timeIntervalSince1970-value.lastBeatAt<8}
    func setKillSwitch(_ enabled:Bool)throws{let data=try JSONSerialization.data(withJSONObject:["killSwitch":enabled],options:[.sortedKeys]);try data.write(to:controlURL,options:.atomic);refresh()}
    func sendServiceJobCommand(action:String,jobID:UUID)throws{let normalized=action.lowercased(),allowed:Set<String>=["pause","resume","retry","delete"];guard allowed.contains(normalized)else{throw WorkerCommandError.unsupported};let command:[String:Any]=["action":normalized,"jobID":jobID.uuidString,"nonce":UUID().uuidString,"createdAt":Date().timeIntervalSince1970];try enqueue(command);if(snapshot?.version ?? 0)<8{let data=try JSONSerialization.data(withJSONObject:command,options:[.sortedKeys]);try data.write(to:legacyCommandURL,options:.atomic)}}
    func enqueueCreateJob(id:UUID,title:String,kind:String,payload:[String:Any],cadenceSeconds:Double?=nil)throws{let now=Date().timeIntervalSince1970;var job:[String:Any]=["id":id.uuidString,"title":title,"kind":kind,"state":"scheduled","createdAt":now,"updatedAt":now,"nextRunAt":now,"payload":payload,"enabled":true,"failures":0,"recoveryCount":0];if let cadenceSeconds{job["cadenceSeconds"]=cadenceSeconds};try enqueue(["action":"create","job":job,"nonce":UUID().uuidString,"createdAt":now])}
    private func enqueue(_ command:[String:Any])throws{var queue:[[String:Any]]=[];if let data=try? Data(contentsOf:commandQueueURL),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let existing=object["commands"] as? [[String:Any]]{queue=existing};queue.append(command);if queue.count>500{throw WorkerCommandError.queueFull};let data=try JSONSerialization.data(withJSONObject:["version":2,"commands":queue],options:[.sortedKeys]);try data.write(to:commandQueueURL,options:.atomic)}
    func resolveServiceJob(_ raw:String)->ServiceJob?{let key=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if let id=UUID(uuidString:key){return serviceJobs.first{$0.id==id}};let matches=serviceJobs.filter{$0.id.uuidString.lowercased().hasPrefix(key)};return matches.count==1 ? matches[0]:nil}
    enum WorkerCommandError:LocalizedError{case unsupported,queueFull;var errorDescription:String?{switch self{case .unsupported:return"Unsupported worker command";case .queueFull:return"Worker command queue is full"}}}
}
