import Foundation
import SwiftData

/// The paper-trading virtual cash balance — a single row (fetched or
/// created on demand by `PersistenceService.paperAccount()`), starting at
/// `PaperTradingConstants.startingBalance` simulated USDT. Never connects
/// to a real exchange account.
///
/// `.unique` on `id` is gone and every non-optional property has an
/// inline default — required for CloudKit-backed SwiftData (see
/// `PersistedChatMessage`). `lastModifiedAt` is new: without a
/// schema-level uniqueness constraint, two devices can each create their
/// own "paper_account" row before ever syncing, ending up as two
/// separate rows once they do — this timestamp is what
/// `PersistenceService.deduplicatePaperAccounts()` uses to keep the most
/// recently touched one after launch. Every `cashBalance` mutation in
/// `PersistenceService` updates it.
@Model
final class PersistedPaperAccount {
    var id: String = "paper_account"
    var cashBalance: Double = 0
    var lastModifiedAt: Date = Date()

    init(id: String = "paper_account", cashBalance: Double, lastModifiedAt: Date = Date()) {
        self.id = id
        self.cashBalance = cashBalance
        self.lastModifiedAt = lastModifiedAt
    }
}
