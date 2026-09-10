import Foundation

struct MarketIndicatorSnapshot: Codable, Hashable {
    var asset: String
    var interval: String
    var price: Double
    var change1hPercent: Double?
    var change4hPercent: Double?
    var change24hPercent: Double?
    var sma20: Double?
    var sma50: Double?
    var ema9: Double?
    var ema21: Double?
    var ema50: Double?
    var rsi14: Double?
    var macd: Double?
    var macdSignal: Double?
    var macdHistogram: Double?
    var atr14: Double?
    var atrPercent: Double?
    var bollingerUpper: Double?
    var bollingerMiddle: Double?
    var bollingerLower: Double?
    var volumeRatio20: Double?
    var realizedVolatilityPercent: Double?
    var trendScore: Double
    var confidence: Double
    var regime: String
    var signal: String
    var evidence: [String]
}

struct MarketWatchlistReport: Codable, Hashable {
    var generatedAt: Date
    var interval: String
    var snapshots: [MarketIndicatorSnapshot]
}

enum MarketIndicatorEngine {
    static func analyze(asset: String, interval: String, candles: [BinanceCandle]) -> MarketIndicatorSnapshot? {
        guard candles.count >= 30, let last = candles.last, last.close > 0 else { return nil }
        let closes = candles.map(\.close)
        let highs = candles.map(\.high)
        let lows = candles.map(\.low)
        let volumes = candles.map(\.volume)
        let ema9 = ema(closes, period: 9)
        let ema21 = ema(closes, period: 21)
        let ema50 = ema(closes, period: 50)
        let sma20 = sma(closes, period: 20)
        let sma50 = sma(closes, period: 50)
        let rsi14 = rsi(closes, period: 14)
        let macdSeries = macd(closes)
        let atr14 = atr(highs: highs, lows: lows, closes: closes, period: 14)
        let bb = bollinger(closes, period: 20, deviations: 2)
        let volumeAverage = average(Array(volumes.suffix(20)))
        let volumeRatio = volumeAverage.map { $0 > 0 ? last.volume / $0 : 0 }
        let rv = realizedVolatility(closes)
        let p1 = percentChange(closes, bars: 1)
        let p4 = percentChange(closes, bars: 4)
        let p24 = percentChange(closes, bars: min(24, max(1, closes.count - 1)))

        var score = 0.0
        var evidence: [String] = []
        if let e9 = ema9, let e21 = ema21 {
            if e9 > e21 { score += 1; evidence.append("EMA9 > EMA21") }
            else { score -= 1; evidence.append("EMA9 < EMA21") }
        }
        if let e21 = ema21, let e50 = ema50 {
            if e21 > e50 { score += 1; evidence.append("EMA21 > EMA50") }
            else { score -= 1; evidence.append("EMA21 < EMA50") }
        }
        if let rsi14 {
            if rsi14 >= 55 && rsi14 <= 72 { score += 0.8; evidence.append(String(format: "RSI %.1f bullish", rsi14)) }
            else if rsi14 <= 45 && rsi14 >= 28 { score -= 0.8; evidence.append(String(format: "RSI %.1f bearish", rsi14)) }
            else if rsi14 > 75 { score -= 0.25; evidence.append(String(format: "RSI %.1f overbought-risk", rsi14)) }
            else if rsi14 < 25 { score += 0.25; evidence.append(String(format: "RSI %.1f oversold-risk", rsi14)) }
        }
        if let h = macdSeries.histogram {
            if h > 0 { score += 0.8; evidence.append("MACD histogram positive") }
            else { score -= 0.8; evidence.append("MACD histogram negative") }
        }
        if let p4 {
            if p4 > 0.5 { score += 0.5; evidence.append(String(format: "4h momentum +%.2f%%", p4)) }
            else if p4 < -0.5 { score -= 0.5; evidence.append(String(format: "4h momentum %.2f%%", p4)) }
        }
        if let volumeRatio, volumeRatio >= 1.25 {
            score += score >= 0 ? 0.35 : -0.35
            evidence.append(String(format: "volume %.2fx 20-bar avg", volumeRatio))
        }
        score = min(4, max(-4, score))
        let confidence = min(0.95, 0.50 + abs(score) / 8.0)
        let atrPct = atr14.map { $0 / last.close * 100 }
        let regime: String
        if let atrPct, atrPct >= 4 { regime = "high-volatility" }
        else if abs(score) >= 2.2 { regime = score > 0 ? "uptrend" : "downtrend" }
        else { regime = "range/mixed" }
        let signal: String
        switch score {
        case 2.4...: signal = "bullish"
        case ...(-2.4): signal = "bearish"
        case 1.0..<2.4: signal = "mild-bullish"
        case -2.4..<(-1.0): signal = "mild-bearish"
        default: signal = "neutral"
        }
        return MarketIndicatorSnapshot(asset: asset.uppercased(), interval: interval, price: last.close, change1hPercent: p1, change4hPercent: p4, change24hPercent: p24, sma20: sma20, sma50: sma50, ema9: ema9, ema21: ema21, ema50: ema50, rsi14: rsi14, macd: macdSeries.value, macdSignal: macdSeries.signal, macdHistogram: macdSeries.histogram, atr14: atr14, atrPercent: atrPct, bollingerUpper: bb.upper, bollingerMiddle: bb.middle, bollingerLower: bb.lower, volumeRatio20: volumeRatio, realizedVolatilityPercent: rv, trendScore: score, confidence: confidence, regime: regime, signal: signal, evidence: evidence)
    }

    private static func sma(_ values: [Double], period: Int) -> Double? { guard values.count >= period else { return nil }; return average(Array(values.suffix(period))) }
    private static func average(_ values: [Double]) -> Double? { guard !values.isEmpty else { return nil }; return values.reduce(0,+) / Double(values.count) }
    private static func emaSeries(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let k = 2.0 / Double(period + 1); var out = [values[0]]
        for v in values.dropFirst() { out.append(v * k + out.last! * (1-k)) }
        return out
    }
    private static func ema(_ values: [Double], period: Int) -> Double? { guard values.count >= period else { return nil }; return emaSeries(values, period: period).last }
    private static func rsi(_ values: [Double], period: Int) -> Double? {
        guard values.count > period else { return nil }; let diffs = zip(values.dropFirst(), values).map(-)
        let recent = Array(diffs.suffix(period)); let gains = recent.map { max($0,0) }.reduce(0,+) / Double(period); let losses = recent.map { max(-$0,0) }.reduce(0,+) / Double(period)
        if losses == 0 { return 100 }; let rs = gains/losses; return 100 - 100/(1+rs)
    }
    private static func macd(_ values: [Double]) -> (value: Double?, signal: Double?, histogram: Double?) {
        guard values.count >= 26 else { return (nil,nil,nil) }; let fast=emaSeries(values,period:12),slow=emaSeries(values,period:26);let line=zip(fast,slow).map(-);guard let value=line.last else{return(nil,nil,nil)};let signal=emaSeries(line,period:9).last;return(value,signal,signal.map{value-$0})
    }
    private static func atr(highs:[Double], lows:[Double], closes:[Double], period:Int)->Double? {
        guard highs.count==lows.count, highs.count==closes.count, closes.count>period else{return nil};var tr:[Double]=[];for i in 1..<closes.count{tr.append(max(highs[i]-lows[i],max(abs(highs[i]-closes[i-1]),abs(lows[i]-closes[i-1]))))};return average(Array(tr.suffix(period)))
    }
    private static func bollinger(_ values:[Double],period:Int,deviations:Double)->(upper:Double?,middle:Double?,lower:Double?){guard values.count>=period else{return(nil,nil,nil)};let v=Array(values.suffix(period));guard let m=average(v)else{return(nil,nil,nil)};let variance=v.map{pow($0-m,2)}.reduce(0,+)/Double(period);let sd=sqrt(variance);return(m+deviations*sd,m,m-deviations*sd)}
    private static func percentChange(_ values:[Double],bars:Int)->Double?{guard bars>0,values.count>bars else{return nil};let old=values[values.count-1-bars];guard old != 0 else{return nil};return (values.last!-old)/old*100}
    private static func realizedVolatility(_ values:[Double])->Double?{guard values.count>=10 else{return nil};let returns=zip(values.dropFirst(),values).compactMap{new,old in old>0 && new>0 ? log(new/old):nil};let sample=Array(returns.suffix(min(24,returns.count)));guard sample.count>1,let mean=average(sample)else{return nil};let variance=sample.map{pow($0-mean,2)}.reduce(0,+)/Double(sample.count-1);return sqrt(variance)*sqrt(Double(sample.count))*100}
}

@MainActor
final class MarketIntelligenceCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "market_intelligence"
    let name = "Crypto Market Intelligence"
    let capabilityDescription = "Read-only crypto market scanner with deterministic RSI, MACD, EMA/SMA, ATR, Bollinger, momentum, volume and volatility analysis. Produces probabilistic signals and evidence; never places orders."
    let keywords = ["market scan","market report","crypto report","technical analysis","indicator","indicators","rsi","macd","τεχνικη αναλυση","τεχνική ανάλυση","δεικτες","δείκτες","αναλυση αγορας","ανάλυση αγοράς"]
    private(set) var status: AgentCapabilityStatus = .idle
    private let marketData: BinanceMarketDataService
    init(marketData: BinanceMarketDataService = .shared) { self.marketData = marketData }
    var descriptor: CapabilityDescriptor { CapabilityDescriptor(id:id,displayName:name,summary:capabilityDescription,domain:.trading,keywords:keywords,policy:CapabilityExecutionPolicy(declaredEffects:[.readOnly],supportsBackgroundExecution:true,supportsProjectContext:true,timeoutSeconds:90,maxAttempts:3),version:1) }
    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
    func resolve(_ action: ProposedAction) {}

    func handle(command:String,recentHistory:[ChatMessage]) async throws -> CapabilityOutcome {
        let normalized=command.uppercased();let known=["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","AVAX","LINK","SUI"]
        let assets=known.filter{normalized.contains($0)}
        if assets.count==1{return try await analyzeOutcome(asset:assets[0],interval:"1h")}
        return try await scanOutcome(assets:assets.isEmpty ? Array(known.prefix(8)):assets,interval:"1h")
    }
    func handle(invocation:DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        switch invocation.operation {
        case "analyze_asset": return try await analyzeOutcome(asset:invocation.arguments["asset"] ?? "BTC",interval:invocation.arguments["interval"] ?? "1h")
        case "scan_watchlist","daily_report":
            let assets=(invocation.arguments["assets"] ?? "BTC,ETH,SOL,XRP,BNB,ADA,DOGE,LINK").split(separator:",").map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)}
            return try await scanOutcome(assets:assets,interval:invocation.arguments["interval"] ?? "1h")
        default:return .reply("Unsupported market-intelligence operation: \(invocation.operation)")
        }
    }
    private func snapshot(asset:String,interval:String) async throws -> MarketIndicatorSnapshot { let candles=try await marketData.recentCandles(for:asset,interval:interval,limit:120);guard let s=MarketIndicatorEngine.analyze(asset:asset,interval:interval,candles:candles) else{throw BinanceMarketDataError.invalidResponse};return s }
    private func analyzeOutcome(asset:String,interval:String) async throws -> CapabilityOutcome { status = .running;defer{status = .idle};return .reply(render(try await snapshot(asset:asset,interval:interval))) }
    private func scanOutcome(assets:[String],interval:String) async throws -> CapabilityOutcome { status = .running;defer{status = .idle};var out:[MarketIndicatorSnapshot]=[];for asset in assets.prefix(20){if let s=try? await snapshot(asset:asset,interval:interval){out.append(s)}};out.sort{abs($0.trendScore)>abs($1.trendScore)};return .reply(render(report:.init(generatedAt:Date(),interval:interval,snapshots:out))) }
    private func render(_ s:MarketIndicatorSnapshot)->String { """
        MARKET INTELLIGENCE — \(s.asset)/USDT [\(s.interval)]
        Price: \(fmt(s.price))
        Signal: \(s.signal.uppercased()) · confidence \(Int(s.confidence*100))% · regime \(s.regime)
        Momentum: 1h \(pct(s.change1hPercent)) · 4h \(pct(s.change4hPercent)) · 24h \(pct(s.change24hPercent))
        RSI14: \(num(s.rsi14)) · MACD hist: \(num(s.macdHistogram))
        EMA9/21/50: \(num(s.ema9)) / \(num(s.ema21)) / \(num(s.ema50))
        ATR14: \(num(s.atr14)) (\(pct(s.atrPercent))) · Volume: \(num(s.volumeRatio20))x
        Bollinger: \(num(s.bollingerLower)) / \(num(s.bollingerMiddle)) / \(num(s.bollingerUpper))
        Evidence: \(s.evidence.joined(separator:", "))
        Signal is probabilistic market analysis, not a guarantee of profit.
        """ }
    private func render(report:MarketWatchlistReport)->String { let rows=report.snapshots.map{"\($0.asset)  \($0.signal.uppercased())  score \(String(format:"%.2f",$0.trendScore))  conf \(Int($0.confidence*100))%  RSI \(num($0.rsi14))  24h \(pct($0.change24hPercent))  \($0.regime)"}.joined(separator:"\n");return "MARKET SCAN — \(report.interval)\n\n\(rows)\n\nRanked by absolute deterministic trend score. Signals are probabilistic; profitability is not guaranteed." }
    private func fmt(_ v:Double)->String{v>=100 ? String(format:"%.2f",v):String(format:"%.6f",v)}
    private func num(_ v:Double?)->String{v.map{String(format:"%.3f",$0)} ?? "n/a"}
    private func pct(_ v:Double?)->String{v.map{String(format:"%+.2f%%",$0)} ?? "n/a"}
}
