import Foundation
import SwiftData

/// A single simulated (paper) crypto position — opened and closed only
/// through `PersistenceService`'s paper-trading methods, which also keep
/// `PersistedPaperAccount.cashBalance` in sync. `closedAt == nil` means
/// the position is still open.
@Model
final class PersistedPaperPosition {
    @Attribute(.unique) var id: UUID
    var asset: String
    var quantity: Double
    var entryPrice: Double
    var stopLossPrice: Double
    var openedAt: Date
    var closedAt: Date?
    var exitPrice: Double?
    var realizedPnL: Double?

    init(
        id: UUID = UUID(),
        asset: String,
        quantity: Double,
        entryPrice: Double,
        stopLossPrice: Double,
        openedAt: Date = Date()
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
    }
}
