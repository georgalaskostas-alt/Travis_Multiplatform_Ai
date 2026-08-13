import Foundation

/// Which trading venue a position or standing mandate applies to.
/// `.paper` (the default everywhere) is 100% local simulation — no API
/// calls, no real order execution. `.testnet` places real, HMAC-signed
/// orders against Binance's SPOT TESTNET (testnet.binance.vision) via
/// `BinanceTestnetTradingService`, using fictitious funds the testnet
/// itself provides — real execution mechanics, zero real money.
///
/// Deliberately no `.live` case yet — that's a separate, future step
/// requiring its own explicit approval; nothing in this enum or anything
/// that switches on it has a path to a real exchange account.
enum TradingMode: String, Codable, CaseIterable, Identifiable {
    case paper
    case testnet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Paper"
        case .testnet: return "Testnet"
        }
    }
}
