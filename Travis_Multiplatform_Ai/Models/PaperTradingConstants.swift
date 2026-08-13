import Foundation

/// Central, tunable constants for the trading risk model used by
/// `CryptoTradingCapability` — identical for both `.paper` and
/// `.testnet` mode (see `TradingMode`), so risk sizing/stop-loss/circuit
/// breaker behave the same regardless of which one is active. Neither
/// mode has a real exchange account or real money at risk. A live mode
/// is an explicit future step that requires separate, deliberate
/// approval; it does not exist yet.
enum PaperTradingConstants {
    /// Starting simulated cash balance for the paper account (USDT).
    static let startingBalance: Double = 10_000

    /// Risk taken per trade when the user doesn't specify one, as a
    /// fraction of the paper account's cash balance.
    static let defaultRiskPercent: Double = 0.01

    /// Hard ceiling on risk per trade, regardless of what's requested.
    static let maxRiskPercent: Double = 0.02

    /// Mandatory stop-loss distance below entry price. Every opened
    /// position gets one — there is no "no stop-loss" trade.
    static let stopLossPercent: Double = 0.03

    /// Once today's realized paper losses reach this amount, opening new
    /// positions is frozen until the next calendar day. Closing existing
    /// positions is still always allowed.
    static let dailyLossLimit: Double = startingBalance * 0.05
}
