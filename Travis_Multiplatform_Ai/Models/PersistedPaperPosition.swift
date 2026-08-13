import Foundation
import SwiftData

/// A single simulated (paper) or real-execution (testnet) crypto
/// position — opened and closed only through `PersistenceService`'s
/// paper-trading methods, which also keep `PersistedPaperAccount.cashBalance`
/// in sync FOR PAPER-MODE POSITIONS ONLY (testnet funds live on Binance's
/// testnet servers, not in our local balance). `closedAt == nil` means
/// the position is still open. `mode` (`TradingMode.rawValue`) is what
/// `PersistenceService` reads to decide whether to touch the local
/// balance on open/close, and what `CryptoTradingCapability` uses to
/// keep paper and testnet positions for the same asset from being
/// treated as the same thing when closing.
///
/// `.unique` on `id` is gone and every non-optional property has an
/// inline default — required for CloudKit-backed SwiftData (see
/// `PersistedChatMessage`). No dedup pass needed here unlike the other
/// singleton-by-key models: each position is already meant to be its
/// own distinct row (a UUID collision across devices is not a realistic
/// concern), so ordinary CloudKit sync is sufficient as-is.
@Model
final class PersistedPaperPosition {
    var id: UUID = UUID()
    var asset: String = ""
    var quantity: Double = 0
    var entryPrice: Double = 0
    var stopLossPrice: Double = 0
    var openedAt: Date = Date()
    var closedAt: Date?
    var exitPrice: Double?
    var realizedPnL: Double?
    var mode: String = TradingMode.paper.rawValue

    init(
        id: UUID = UUID(),
        asset: String,
        quantity: Double,
        entryPrice: Double,
        stopLossPrice: Double,
        openedAt: Date = Date(),
        mode: String = TradingMode.paper.rawValue
    ) {
        self.id = id
        self.asset = asset
        self.quantity = quantity
        self.entryPrice = entryPrice
        self.stopLossPrice = stopLossPrice
        self.openedAt = openedAt
        self.closedAt = nil
        self.exitPrice = nil
        self.realizedPnL = nil
        self.mode = mode
    }
}
