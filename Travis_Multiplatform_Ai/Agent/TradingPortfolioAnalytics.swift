import Foundation
import SwiftData

struct TradingPerformanceSnapshot: Codable, Hashable {
    var mode:String
    var generatedAt:Date
    var openPositions:Int
    var closedTrades:Int
    var realizedPnL:Double
    var todaysRealizedPnL:Double
    var wins:Int
    var losses:Int
    var winRate:Double
    var averageWin:Double?
    var averageLoss:Double?
    var profitFactor:Double?
    var bestTrade:Double?
    var worstTrade:Double?
}

@MainActor
extension PersistenceService {
    func tradingPositions(mode:TradingMode?=nil)->[PersistedPaperPosition] {
        let all=(try? container.mainContext.fetch(FetchDescriptor<PersistedPaperPosition>(sortBy:[SortDescriptor(\.openedAt,order:.reverse)]))) ?? []
        guard let mode else{return all}
        return all.filter{$0.mode == mode.rawValue}
    }

    func tradingPerformance(mode:TradingMode)->TradingPerformanceSnapshot {
        let positions=tradingPositions(mode:mode),closed=positions.filter{$0.closedAt != nil},pnls=closed.compactMap(\.realizedPnL),wins=pnls.filter{$0>0},losses=pnls.filter{$0<0}
        let start=Calendar.current.startOfDay(for:Date())
        let today=closed.filter{($0.closedAt ?? .distantPast)>=start}.compactMap(\.realizedPnL).reduce(0,+)
        let grossWin=wins.reduce(0,+),grossLoss=abs(losses.reduce(0,+))
        return .init(mode:mode.rawValue,generatedAt:Date(),openPositions:positions.filter{$0.closedAt == nil}.count,closedTrades:closed.count,realizedPnL:pnls.reduce(0,+),todaysRealizedPnL:today,wins:wins.count,losses:losses.count,winRate:closed.isEmpty ? 0:Double(wins.count)/Double(closed.count),averageWin:wins.isEmpty ? nil:grossWin/Double(wins.count),averageLoss:losses.isEmpty ? nil:losses.reduce(0,+)/Double(losses.count),profitFactor:grossLoss>0 ? grossWin/grossLoss:nil,bestTrade:pnls.max(),worstTrade:pnls.min())
    }

    func renderTradingPerformanceReport(mode:TradingMode)->String {
        let p=tradingPerformance(mode:mode)
        func money(_ x:Double)->String{String(format:"%+.2f USDT",x)}
        func opt(_ x:Double?)->String{x.map{String(format:"%.2f",$0)} ?? "n/a"}
        return """
        TRAVIS TRADING PERFORMANCE — \(mode.title.uppercased())

        Open positions: \(p.openPositions)
        Closed trades: \(p.closedTrades)
        Realized P&L: \(money(p.realizedPnL))
        Today's realized P&L: \(money(p.todaysRealizedPnL))
        Wins / Losses: \(p.wins) / \(p.losses)
        Win rate: \(String(format:"%.1f%%",p.winRate*100))
        Profit factor: \(opt(p.profitFactor))
        Average win: \(p.averageWin.map(money) ?? "n/a")
        Average loss: \(p.averageLoss.map(money) ?? "n/a")
        Best trade: \(p.bestTrade.map(money) ?? "n/a")
        Worst trade: \(p.worstTrade.map(money) ?? "n/a")
        """
    }
}
