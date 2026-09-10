import Foundation

/// Deterministic authority for every future trading executor. Models may research,
/// rank or propose, but they do not decide whether an order is admissible.
enum TradingRiskKernel {
    struct Limits: Codable, Hashable {
        var maxPositionNotional: Double = 1_000
        var maxPortfolioNotional: Double = 3_000
        var maxOpenPositions: Int = 3
        var maxDailyLoss: Double = 250
        var maxDrawdownPercent: Double = 8
        var maxOrderNotional: Double = 1_000
        var minStopDistancePercent: Double = 0.25
        var maxStopDistancePercent: Double = 8
        var allowedAssets: Set<String> = ["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"]
    }

    struct Snapshot: Codable, Hashable {
        var mode: String
        var equity: Double
        var currentPortfolioNotional: Double
        var openPositions: Int
        var dailyRealizedPnL: Double
        var peakEquity: Double
        var killSwitch: Bool
        var recentOrderKeys: Set<String>
    }

    struct OrderIntent: Codable, Hashable {
        enum Side:String,Codable{case buy,sell}
        var asset:String
        var side:Side
        var quantity:Double
        var referencePrice:Double
        var stopLossPrice:Double?
        var idempotencyKey:String
    }

    struct Decision: Codable, Hashable {
        var allowed:Bool
        var reasons:[String]
        var orderNotional:Double
        var projectedPortfolioNotional:Double
        var drawdownPercent:Double
        var normalizedAsset:String
    }

    static func evaluate(_ intent:OrderIntent,snapshot:Snapshot,limits:Limits)->Decision{
        let asset=intent.asset.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        let notional=max(0,intent.quantity)*max(0,intent.referencePrice)
        let projected=intent.side == .buy ? snapshot.currentPortfolioNotional+notional:max(0,snapshot.currentPortfolioNotional-notional)
        let peak=max(snapshot.peakEquity,snapshot.equity,0.01)
        let drawdown=max(0,(peak-snapshot.equity)/peak*100)
        var reasons:[String]=[]
        if snapshot.killSwitch{reasons.append("Emergency kill switch active")}
        if !["paper","testnet"].contains(snapshot.mode.lowercased()){reasons.append("Production/live execution is not enabled by this kernel")}
        if !limits.allowedAssets.contains(asset){reasons.append("Asset is outside deterministic allowlist")}
        if intent.quantity<=0 || !intent.quantity.isFinite{reasons.append("Quantity must be finite and positive")}
        if intent.referencePrice<=0 || !intent.referencePrice.isFinite{reasons.append("Reference price must be finite and positive")}
        if notional>limits.maxOrderNotional{reasons.append("Order notional exceeds per-order limit")}
        if intent.side == .buy && notional>limits.maxPositionNotional{reasons.append("Position notional exceeds per-position limit")}
        if intent.side == .buy && projected>limits.maxPortfolioNotional{reasons.append("Projected portfolio exposure exceeds portfolio limit")}
        if intent.side == .buy && snapshot.openPositions>=limits.maxOpenPositions{reasons.append("Maximum open positions reached")}
        if snapshot.dailyRealizedPnL <= -abs(limits.maxDailyLoss){reasons.append("Daily loss circuit breaker active")}
        if drawdown>=limits.maxDrawdownPercent{reasons.append("Portfolio drawdown circuit breaker active")}
        if intent.idempotencyKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{reasons.append("Idempotency key missing")}
        if snapshot.recentOrderKeys.contains(intent.idempotencyKey){reasons.append("Duplicate order idempotency key")}
        if intent.side == .buy {
            guard let stop=intent.stopLossPrice,stop>0,stop<intent.referencePrice else {
                reasons.append("Long entry requires stop-loss below reference price")
                return .init(allowed:false,reasons:reasons,orderNotional:notional,projectedPortfolioNotional:projected,drawdownPercent:drawdown,normalizedAsset:asset)
            }
            let distance=(intent.referencePrice-stop)/intent.referencePrice*100
            if distance<limits.minStopDistancePercent{reasons.append("Stop-loss is unrealistically tight")}
            if distance>limits.maxStopDistancePercent{reasons.append("Stop-loss exceeds maximum permitted risk distance")}
        }
        return .init(allowed:reasons.isEmpty,reasons:reasons,orderNotional:notional,projectedPortfolioNotional:projected,drawdownPercent:drawdown,normalizedAsset:asset)
    }

    /// Risk-based sizing independent of language-model output. The caller may use
    /// a model-derived setup, but quantity is clipped by deterministic limits.
    static func positionSize(equity:Double,riskFraction:Double,entry:Double,stop:Double,limits:Limits)->Double{
        guard equity>0,entry>0,stop>0,stop<entry else{return 0}
        let boundedRisk=min(max(riskFraction,0.0001),0.02)
        let riskBudget=equity*boundedRisk
        let riskPerUnit=entry-stop
        let byRisk=riskBudget/riskPerUnit
        let byNotional=min(limits.maxOrderNotional,limits.maxPositionNotional)/entry
        return max(0,min(byRisk,byNotional))
    }
}
