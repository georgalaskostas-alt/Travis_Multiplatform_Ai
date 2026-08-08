import Foundation
import SwiftData

/// The paper-trading virtual cash balance — a single row (fetched or
/// created on demand by `PersistenceService.paperAccount()`), starting at
/// `PaperTradingConstants.startingBalance` simulated USDT. Never connects
/// to a real exchange account.
@Model
final class PersistedPaperAccount {
    @Attribute(.unique) var id: String
    var cashBalance: Double

    init(id: String = "paper_account", cashBalance: Double) {
        self.id = id
        self.cashBalance = cashBalance
    }
}
