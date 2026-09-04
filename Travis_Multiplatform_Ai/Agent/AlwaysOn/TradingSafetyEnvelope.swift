import Foundation

struct TradingSafetyEnvelope: Codable, Equatable {
    var mode: AlwaysOnJobKind = .tradingPaper
    var maxPositionNotional: Double
    var maxDailyLoss: Double
    var maxOpenPositions: Int
    var requireStopLoss = true
    var allowLiveTrading = false

    func validate() throws {
        guard mode == .tradingPaper || mode == .tradingTestnet else { throw TradingSafetyError.invalidMode }
        guard !allowLiveTrading else { throw TradingSafetyError.liveTradingDisabled }
        guard maxPositionNotional > 0, maxDailyLoss > 0, maxOpenPositions > 0 else { throw TradingSafetyError.invalidLimits }
    }
}

enum TradingSafetyError: LocalizedError { case invalidMode, liveTradingDisabled, invalidLimits
    var errorDescription:String? { switch self { case .invalidMode:return "Always-on trading supports paper/testnet jobs only.";case .liveTradingDisabled:return "Live-money trading is intentionally disabled.";case .invalidLimits:return "Trading risk limits must be positive." } }
}
