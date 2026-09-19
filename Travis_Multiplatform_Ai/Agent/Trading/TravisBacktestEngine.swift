import Foundation

struct TravisBacktestBar: Codable, Sendable {
    let timestamp: Date
    let close: Double
}

struct TravisBacktestResult: Codable, Sendable {
    let startingEquity: Double
    let endingEquity: Double
    let netPnL: Double
    let maxDrawdown: Double
    let trades: Int
    let wins: Int
    let losses: Int
    let profitFactor: Double
    let expectancy: Double
}

struct TravisBacktestEngine {
    // Deterministic long/flat signal backtester with fee + slippage modeling.
    func run(bars: [TravisBacktestBar], signals: [Int: TravisTradeSide], startingEquity: Double = 10_000, allocationFraction: Double = 0.10, feeRate: Double = 0.001, slippageBps: Double = 3) -> TravisBacktestResult {
        guard bars.count > 1 else { return TravisBacktestResult(startingEquity: startingEquity, endingEquity: startingEquity, netPnL: 0, maxDrawdown: 0, trades: 0, wins: 0, losses: 0, profitFactor: 0, expectancy: 0) }
        var equity = startingEquity, peak = startingEquity, maxDD = 0.0
        var entry: Double?, quantity = 0.0, trades = 0, wins = 0, losses = 0, grossProfit = 0.0, grossLoss = 0.0
        for (index, bar) in bars.enumerated() {
            guard let side = signals[index] else { continue }
            if side == .buy, entry == nil {
                let fill = bar.close * (1 + slippageBps / 10_000)
                quantity = (equity * allocationFraction) / fill
                equity -= quantity * fill * feeRate
                entry = fill
            } else if side == .sell, let open = entry {
                let fill = bar.close * (1 - slippageBps / 10_000)
                let pnl = quantity * (fill - open) - quantity * fill * feeRate
                equity += pnl; trades += 1
                if pnl >= 0 { wins += 1; grossProfit += pnl } else { losses += 1; grossLoss += abs(pnl) }
                entry = nil; quantity = 0
                peak = max(peak, equity); maxDD = max(maxDD, peak > 0 ? (peak - equity) / peak : 0)
            }
        }
        let net = equity - startingEquity
        return TravisBacktestResult(startingEquity: startingEquity, endingEquity: equity, netPnL: net, maxDrawdown: maxDD, trades: trades, wins: wins, losses: losses, profitFactor: grossLoss > 0 ? grossProfit / grossLoss : (grossProfit > 0 ? .infinity : 0), expectancy: trades > 0 ? net / Double(trades) : 0)
    }
}
