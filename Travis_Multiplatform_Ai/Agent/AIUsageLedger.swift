import Foundation
import Observation

@MainActor @Observable
final class AIUsageLedger {
    static let shared = AIUsageLedger()
    private struct Snapshot:Codable{var version:Int;var records:[AIUsageRecord];var pricing:[String:AIModelPricing]}
    private(set)var records:[AIUsageRecord]=[];private(set)var pricing:[String:AIModelPricing]=[:];private(set)var persistenceError:String?
    private let maxRecords=10_000;private let fileURL:URL
    private init(){let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.temporaryDirectory;let directory=base.appendingPathComponent("TRAVIS",isDirectory:true);try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);fileURL=directory.appendingPathComponent("ai-usage-v1.json");reload();installBuiltInPricingIfMissing()}
    func record(selection:AIModelSelection,context:AIInvocationContext,usage:AITokenUsage,latencyMilliseconds:Int,attempt:Int,succeeded:Bool,errorType:String?=nil){let price=pricingFor(provider:selection.provider,model:selection.model);records.append(AIUsageRecord(provider:selection.provider,model:selection.model,tier:selection.tier,context:context,usage:usage,estimatedCostUSD:price?.estimatedCost(for:usage),latencyMilliseconds:latencyMilliseconds,attempt:attempt,succeeded:succeeded,errorType:errorType));if records.count>maxRecords{records.removeFirst(records.count-maxRecords)};rebuildRoutingProjections();persist()}
    func setPricing(provider:AIProvider,model:String,pricing value:AIModelPricing){pricing[pricingKey(provider:provider,model:model)]=value;recomputeEstimatedCosts();rebuildRoutingProjections();persist()}
    func removePricing(provider:AIProvider,model:String){pricing.removeValue(forKey:pricingKey(provider:provider,model:model));recomputeEstimatedCosts();rebuildRoutingProjections();persist()}
    func pricingFor(provider:AIProvider,model:String)->AIModelPricing?{pricing[pricingKey(provider:provider,model:model)]}
    func taskUsage(taskId:UUID)->AITokenUsage{records.lazy.filter{$0.taskId==taskId}.reduce(into:AITokenUsage()){r,x in r.inputTokens += x.usage.inputTokens;r.outputTokens += x.usage.outputTokens;r.cachedInputTokens += x.usage.cachedInputTokens;r.reasoningTokens += x.usage.reasoningTokens}}
    func hasUnknownCostUsage(taskId:UUID)->Bool{records.contains{$0.taskId==taskId && $0.succeeded && $0.estimatedCostUSD==nil && $0.usage.totalTokens>0}}
    func estimatedSpendUSD(since date:Date?=nil,taskId:UUID?=nil)->Double{records.lazy.filter{(date==nil || $0.timestamp>=date!)&&(taskId==nil || $0.taskId==taskId)}.compactMap(\.estimatedCostUSD).reduce(0,+)}
    func usageSummary(since date:Date?=nil)->AITokenUsage{records.lazy.filter{date==nil || $0.timestamp>=date!}.reduce(into:AITokenUsage()){r,x in r.inputTokens += x.usage.inputTokens;r.outputTokens += x.usage.outputTokens;r.cachedInputTokens += x.usage.cachedInputTokens;r.reasoningTokens += x.usage.reasoningTokens}}
    func efficiencySummary(since date:Date?=nil)->(requests:Int,cachedInputRatio:Double,costUSD:Double,reasoningTokens:Int){let rows=records.filter{date==nil || $0.timestamp>=date!},usage=rows.reduce(into:AITokenUsage()){r,x in r.inputTokens += x.usage.inputTokens;r.outputTokens += x.usage.outputTokens;r.cachedInputTokens += x.usage.cachedInputTokens;r.reasoningTokens += x.usage.reasoningTokens};let ratio=usage.inputTokens>0 ? Double(usage.cachedInputTokens)/Double(usage.inputTokens):0;return(rows.count,ratio,rows.compactMap(\.estimatedCostUSD).reduce(0,+),usage.reasoningTokens)}
    func diagnosticReport(now:Date=Date())->String{let calendar=Calendar.current,startDay=calendar.startOfDay(for:now),startMonth=calendar.date(from:calendar.dateComponents([.year,.month],from:now)) ?? calendar.startOfDay(for:now),day=usageSummary(since:startDay),month=usageSummary(since:startMonth),dayCost=estimatedSpendUSD(since:startDay),monthCost=estimatedSpendUSD(since:startMonth),unknown=records.filter{$0.estimatedCostUSD==nil && $0.succeeded && $0.usage.totalTokens>0}.count,eff=efficiencySummary(since:startMonth);let providers=Dictionary(grouping:records,by:{$0.provider.rawValue}).map{k,v in "\(k): \(v.reduce(0){$0+$1.usage.totalTokens}) tokens | $\(String(format:"%.4f",v.compactMap(\.estimatedCostUSD).reduce(0,+))) estimated"}.sorted().joined(separator:"\n");return """
TRAVIS AI COST GOVERNOR
TODAY · $\(String(format:"%.4f",dayCost)) · input \(day.inputTokens) · cached \(day.cachedInputTokens) · output \(day.outputTokens) · reasoning \(day.reasoningTokens)
THIS MONTH · $\(String(format:"%.4f",monthCost)) · requests \(eff.requests) · cache hit input \(String(format:"%.1f",eff.cachedInputRatio*100))% · reasoning \(eff.reasoningTokens)
BY PROVIDER
\(providers.isEmpty ? "No usage yet":providers)
RECORDS \(records.count) · COST-UNKNOWN \(unknown)
Policy: local/deterministic first; Luna routine; Terra complex; Sol frontier; escalate only when required.
"""}
    func reload(){guard FileManager.default.fileExists(atPath:fileURL.path)else{rebuildRoutingProjections();return};do{let data=try Data(contentsOf:fileURL),snapshot=try? JSONDecoder().decode(Snapshot.self,from:data);guard let snapshot,snapshot.version==1 else{return};records=snapshot.records;pricing=snapshot.pricing;rebuildRoutingProjections();persistenceError=nil}catch{persistenceError=error.localizedDescription}}
    private func installBuiltInPricingIfMissing(){let defaults:[(AIProvider,String,AIModelPricing)]=[(.openAI,"gpt-5.6-luna",.init(inputUSDPerMillion:0.20,outputUSDPerMillion:1.20,cachedInputUSDPerMillion:0.02)),(.openAI,"gpt-5.6-terra",.init(inputUSDPerMillion:2.00,outputUSDPerMillion:12.00,cachedInputUSDPerMillion:0.20)),(.openAI,"gpt-5.6-sol",.init(inputUSDPerMillion:4.00,outputUSDPerMillion:20.00,cachedInputUSDPerMillion:0.40))];var changed=false;for(provider,model,value) in defaults{let key=pricingKey(provider:provider,model:model);if pricing[key]==nil{pricing[key]=value;changed=true}};if changed{recomputeEstimatedCosts();rebuildRoutingProjections();persist()}}
    private func recomputeEstimatedCosts(){for i in records.indices{let r=records[i];records[i].estimatedCostUSD=pricingFor(provider:r.provider,model:r.model)?.estimatedCost(for:r.usage)}}
    private func rebuildRoutingProjections(){AIAdaptiveRoutingRegistry.shared.rebuild(from:records);AIModelCircuitBreaker.shared.rebuild(from:records)}
    private func persist(){do{let snapshot=Snapshot(version:1,records:records,pricing:pricing),data=try JSONEncoder().encode(snapshot),tmp=fileURL.appendingPathExtension("tmp");try data.write(to:tmp,options:.atomic);if FileManager.default.fileExists(atPath:fileURL.path){_=try FileManager.default.replaceItemAt(fileURL,withItemAt:tmp)}else{try FileManager.default.moveItem(at:tmp,to:fileURL)};persistenceError=nil}catch{persistenceError=error.localizedDescription}}
    private func pricingKey(provider:AIProvider,model:String)->String{"\(provider.rawValue.lowercased())::\(model.lowercased())"}
}
