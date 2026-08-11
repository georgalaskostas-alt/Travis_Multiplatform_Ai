import Foundation
import SwiftData

/// A single simulated (paper) crypto position — opened and closed only
/// through `PersistenceService`'s paper-trading methods, which also keep
/// `PersistedPaperAccount.cashBalance` in sync. `closedAt == nil` means
/// the position is still open.
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
