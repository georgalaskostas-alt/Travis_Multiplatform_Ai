import Foundation

struct MarketIndicatorSnapshot: Codable, Hashable {
    var asset:String; var interval:String; var price:Double
    var change1hPercent:Double?; var change4hPercent:Double?; var change24hPercent:Double?
    var sma20:Double?; var sma50:Double?; var ema9:Double?; var ema21:Double?; var ema50:Double?
    var rsi14:Double?; var macd:Double?; var macdSignal:Double?; var macdHistogram:Double?
    var atr14:Double?; var atrPercent:Double?; var bollingerUpper:Double?; var bollingerMiddle:Double?; var bollingerLower:Double?
    var volumeRatio20:Double?; var realizedVolatilityPercent:Double?
    var trendScore:Double; var confidence:Double; var regime:String; var signal:String; var evidence:[String]
}

struct MarketWatchlistReport: Codable, Hashable { var generatedAt:Date; var interval:String; var snapshots:[MarketIndicatorSnapshot] }

enum MarketIndicatorEngine {
    static func analyze(asset:String,interval:String,candles:[BinanceCandle])->MarketIndicatorSnapshot? {
        guard candles.count >= 30, let last=candles.last, last.close > 0 else{return nil}
        let c=candles.map(\.close), h=candles.map(\.high), l=candles.map(\.low), v=candles.map(\.volume)
        let e9=ema(c,9),e21=ema(c,21),e50=ema(c,50),s20=sma(c,20),s50=sma(c,50),r=rsi(c,14),m=macd(c),a=atr(h,l,c,14),b=bollinger(c,20),vr=average(Array(v.suffix(20))).map{$0>0 ? last.volume/$0:0},rv=volatility(c)
        let p1=pct(c,1),p4=pct(c,4),p24=pct(c,min(24,max(1,c.count-1)))
        var score=0.0;var evidence:[String]=[]
        if let x=e9,let y=e21 { score += x>y ? 1:-1; evidence.append(x>y ? "EMA9 > EMA21":"EMA9 < EMA21") }
        if let x=e21,let y=e50 { score += x>y ? 1:-1; evidence.append(x>y ? "EMA21 > EMA50":"EMA21 < EMA50") }
        if let r { if (55...72).contains(r){score += 0.8;evidence.append("RSI bullish")} else if (28...45).contains(r){score -= 0.8;evidence.append("RSI bearish")} else if r>75{score -= 0.25;evidence.append("RSI overbought-risk")} else if r<25{score += 0.25;evidence.append("RSI oversold-risk")} }
        if let hist=m.histogram { score += hist>0 ? 0.8:-0.8; evidence.append(hist>0 ? "MACD histogram positive":"MACD histogram negative") }
        if let p4 { if p4>0.5{score += 0.5;evidence.append("4h momentum positive")} else if p4 < -0.5{score -= 0.5;evidence.append("4h momentum negative")} }
        if let vr,vr>=1.25 { score += score>=0 ? 0.35:-0.35;evidence.append("volume confirmation") }
        score=max(-4,min(4,score));let confidence=min(0.95,0.5+abs(score)/8);let atrPct=a.map{$0/last.close*100}
        let regime = (atrPct ?? 0)>=4 ? "high-volatility":score>=2.2 ? "uptrend":score<=(-2.2) ? "downtrend":"range/mixed"
        let signal = score>=2.4 ? "bullish":score<=(-2.4) ? "bearish":score>=1 ? "mild-bullish":score<=(-1) ? "mild-bearish":"neutral"
        return .init(asset:asset.uppercased(),interval:interval,price:last.close,change1hPercent:p1,change4hPercent:p4,change24hPercent:p24,sma20:s20,sma50:s50,ema9:e9,ema21:e21,ema50:e50,rsi14:r,macd:m.value,macdSignal:m.signal,macdHistogram:m.histogram,atr14:a,atrPercent:atrPct,bollingerUpper:b.upper,bollingerMiddle:b.middle,bollingerLower:b.lower,volumeRatio20:vr,realizedVolatilityPercent:rv,trendScore:score,confidence:confidence,regime:regime,signal:signal,evidence:evidence)
    }
    private static func average(_ x:[Double])->Double?{x.isEmpty ? nil:x.reduce(0,+)/Double(x.count)}
    private static func sma(_ x:[Double],_ n:Int)->Double?{x.count>=n ? average(Array(x.suffix(n))):nil}
    private static func emaSeries(_ x:[Double],_ n:Int)->[Double]{guard let first=x.first else{return []};let k=2.0/Double(n+1);var out=[first];for value in x.dropFirst(){out.append(value*k+out[out.count-1]*(1-k))};return out}
    private static func ema(_ x:[Double],_ n:Int)->Double?{x.count>=n ? emaSeries(x,n).last:nil}
    private static func rsi(_ x:[Double],_ n:Int)->Double?{guard x.count>n else{return nil};var diffs:[Double]=[];for i in 1..<x.count{diffs.append(x[i]-x[i-1])};let d=Array(diffs.suffix(n));let g=d.reduce(0){$0+max($1,0)}/Double(n),loss=d.reduce(0){$0+max(-$1,0)}/Double(n);if loss==0{return 100};return 100-100/(1+g/loss)}
    private static func macd(_ x:[Double])->(value:Double?,signal:Double?,histogram:Double?){guard x.count>=26 else{return(nil,nil,nil)};let f=emaSeries(x,12),s=emaSeries(x,26);var line:[Double]=[];for i in 0..<min(f.count,s.count){line.append(f[i]-s[i])};guard let value=line.last,let signal=emaSeries(line,9).last else{return(nil,nil,nil)};return(value,signal,value-signal)}
    private static func atr(_ h:[Double],_ l:[Double],_ c:[Double],_ n:Int)->Double?{guard h.count==l.count,h.count==c.count,c.count>n else{return nil};var tr:[Double]=[];for i in 1..<c.count{tr.append(max(h[i]-l[i],max(abs(h[i]-c[i-1]),abs(l[i]-c[i-1]))))};return average(Array(tr.suffix(n)))}
    private static func bollinger(_ x:[Double],_ n:Int)->(upper:Double?,middle:Double?,lower:Double?){guard x.count>=n else{return(nil,nil,nil)};let v=Array(x.suffix(n));guard let mean=average(v)else{return(nil,nil,nil)};let variance=v.reduce(0){$0+pow($1-mean,2)}/Double(n),sd=sqrt(variance);return(mean+2*sd,mean,mean-2*sd)}
    private static func pct(_ x:[Double],_ bars:Int)->Double?{guard bars>0,x.count>bars else{return nil};let old=x[x.count-1-bars];return old==0 ? nil:(x[x.count-1]/old-1)*100}
    private static func volatility(_ x:[Double])->Double?{guard x.count>=10 else{return nil};var r:[Double]=[];for i in 1..<x.count where x[i]>0 && x[i-1]>0{r.append(log(x[i]/x[i-1]))};let s=Array(r.suffix(min(24,r.count)));guard s.count>1,let mean=average(s)else{return nil};let variance=s.reduce(0){$0+pow($1-mean,2)}/Double(s.count-1);return sqrt(variance)*sqrt(Double(s.count))*100}
}

@MainActor final class MarketIntelligenceCapability:AgentCapability,DeterministicInvocableCapability,DeterministicInvocationPolicyProviding {
    let id="market_intelligence",name="Crypto Market Intelligence",capabilityDescription="Read-only crypto market scanner with deterministic RSI, MACD, EMA/SMA, ATR, Bollinger, momentum, volume and volatility analysis. Produces probabilistic signals and evidence; never places orders."
    let keywords=["market scan","market report","crypto report","technical analysis","indicator","indicators","rsi","macd","τεχνικη αναλυση","τεχνική ανάλυση","δεικτες","δείκτες","αναλυση αγορας","ανάλυση αγοράς"]
    private(set)var status:AgentCapabilityStatus = .idle;private let marketData:BinanceMarketDataService
    init(marketData:BinanceMarketDataService = .shared){self.marketData=marketData}
    var descriptor:CapabilityDescriptor{.init(id:id,displayName:name,summary:capabilityDescription,domain:.trading,keywords:keywords,policy:.init(declaredEffects:[.readOnly],supportsBackgroundExecution:true,supportsProjectContext:true,timeoutSeconds:90,maxAttempts:3))}
    func requiresApproval(for invocation:DeterministicCapabilityInvocation)->Bool{false};func riskLevel(for invocation:DeterministicCapabilityInvocation)->PlanStepRiskLevel{.low};func resolve(_ action:ProposedAction){}
    func handle(command:String,recentHistory:[ChatMessage])async throws->CapabilityOutcome{let upper=command.uppercased(),known=["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","AVAX","LINK","SUI"],assets=known.filter{upper.contains($0)};return assets.count==1 ? try await analyze(asset:assets[0],interval:"1h"):try await scan(assets:assets.isEmpty ? Array(known.prefix(8)):assets,interval:"1h")}
    func handle(invocation:DeterministicCapabilityInvocation)async throws->CapabilityOutcome{switch invocation.operation{case "analyze_asset":return try await analyze(asset:invocation.arguments["asset"] ?? "BTC",interval:invocation.arguments["interval"] ?? "1h");case "scan_watchlist","daily_report":let assets=(invocation.arguments["assets"] ?? "BTC,ETH,SOL,XRP,BNB,ADA,DOGE,LINK").split(separator:",").map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)};return try await scan(assets:assets,interval:invocation.arguments["interval"] ?? "1h");default:return .reply("Unsupported market-intelligence operation: \(invocation.operation)")}}
    private func snapshot(_ asset:String,_ interval:String)async throws->MarketIndicatorSnapshot{let candles=try await marketData.recentCandles(for:asset,interval:interval,limit:120);guard let s=MarketIndicatorEngine.analyze(asset:asset,interval:interval,candles:candles)else{throw BinanceMarketDataError.invalidResponse};return s}
    private func analyze(asset:String,interval:String)async throws->CapabilityOutcome{status = .running;defer{status = .idle};let s=try await snapshot(asset,interval);return .reply("MARKET INTELLIGENCE — \(s.asset)/USDT [\(s.interval)]\nPrice: \(fmt(s.price))\nSignal: \(s.signal.uppercased()) · confidence \(Int(s.confidence*100))% · regime \(s.regime)\nMomentum: 1h \(pct(s.change1hPercent)) · 4h \(pct(s.change4hPercent)) · 24h \(pct(s.change24hPercent))\nRSI14: \(num(s.rsi14)) · MACD hist: \(num(s.macdHistogram))\nEMA9/21/50: \(num(s.ema9)) / \(num(s.ema21)) / \(num(s.ema50))\nATR: \(pct(s.atrPercent)) · Volume: \(num(s.volumeRatio20))x\nEvidence: \(s.evidence.joined(separator:", "))\nProbabilistic analysis; no guaranteed profit.")}
    private func scan(assets:[String],interval:String)async throws->CapabilityOutcome{status = .running;defer{status = .idle};var out:[MarketIndicatorSnapshot]=[];for a in assets.prefix(20){if let s=try? await snapshot(a,interval){out.append(s)}};out.sort{abs($0.trendScore)>abs($1.trendScore)};let rows=out.map{"\($0.asset)  \($0.signal.uppercased())  score \(String(format:"%.2f",$0.trendScore))  conf \(Int($0.confidence*100))%  RSI \(num($0.rsi14))  24h \(pct($0.change24hPercent))"}.joined(separator:"\n");return .reply("MARKET SCAN — \(interval)\n\n\(rows)\n\nSignals are probabilistic; profitability is not guaranteed.")}
    private func fmt(_ x:Double)->String{x>=100 ? String(format:"%.2f",x):String(format:"%.6f",x)};private func num(_ x:Double?)->String{x.map{String(format:"%.3f",$0)} ?? "n/a"};private func pct(_ x:Double?)->String{x.map{String(format:"%+.2f%%",$0)} ?? "n/a"}
}
