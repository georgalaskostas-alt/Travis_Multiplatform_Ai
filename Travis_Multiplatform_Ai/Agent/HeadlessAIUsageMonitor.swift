import Foundation

@MainActor
final class HeadlessAIUsageMonitor {
    static let shared=HeadlessAIUsageMonitor()
    struct Summary:Equatable{var requests:Int=0;var cachedResponses:Int=0;var estimatedCostUSD:Double=0;var inputTokens:Int=0;var cachedInputTokens:Int=0;var outputTokens:Int=0;var cacheRatio:Double{inputTokens>0 ? Double(cachedInputTokens)/Double(inputTokens):0}}
    private let fileURL:URL
    private init(){let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.temporaryDirectory;fileURL=base.appendingPathComponent("TRAVIS/AlwaysOn/headless-ai-usage-v2.jsonl")}
    func summary(since:Date?=nil)->Summary{guard let text=try? String(contentsOf:fileURL,encoding:.utf8)else{return .init()};var out=Summary();for line in text.split(separator:"\n"){guard let data=String(line).data(using:.utf8),let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any]else{continue};if let since,let at=row["at"] as? Double,Date(timeIntervalSince1970:at)<since{continue};out.requests += 1;out.cachedResponses += (row["localResponseCache"] as? Bool)==true ? 1:0;out.estimatedCostUSD += row["estimatedCostUSD"] as? Double ?? 0;out.inputTokens += row["inputTokens"] as? Int ?? 0;out.cachedInputTokens += row["cachedInputTokens"] as? Int ?? 0;out.outputTokens += row["outputTokens"] as? Int ?? 0};return out}
    func diagnosticReport(now:Date=Date())->String{let cal=Calendar.current,start=cal.startOfDay(for:now),day=summary(since:start),all=summary();return """
TRAVIS HEADLESS AI COST
TODAY · requests \(day.requests) · exact-cache \(day.cachedResponses) · $\(String(format:"%.4f",day.estimatedCostUSD))
ALL RECORDED · requests \(all.requests) · exact-cache \(all.cachedResponses) · $\(String(format:"%.4f",all.estimatedCostUSD))
TOKENS · input \(all.inputTokens) · provider-cached \(all.cachedInputTokens) · output \(all.outputTokens)
POLICY · local exact cache → Luna routine → Terra complex → Sol frontier → cross-provider fallback
"""}
}
