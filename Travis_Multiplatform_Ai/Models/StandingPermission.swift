import Foundation
import SwiftData

/// A standing permission the user grants once and TRAVIS remembers until
/// explicitly revoked — e.g. "you can save files" today, a trading
/// standing mandate later. Deliberately generic: callers own their own
/// key strings (e.g. "file_save"), so unrelated standing permissions can
/// coexist without this model knowing anything about what they gate.
///
/// `.unique` on `key` is gone and every non-optional property has an
/// inline default — required for CloudKit-backed SwiftData (see
/// `PersistedChatMessage`). Without a schema-level uniqueness
/// constraint, two devices granting/revoking the same key while offline
/// can both sync up as separate rows —
/// `PersistenceService.deduplicateStandingPermissions()` cleans those up
/// after launch, keeping the most recent.
@Model
final class StandingPermission {
    var key: String = ""
    var granted: Bool = false
    var grantedAt: Date = Date()

    init(key: String, granted: Bool, grantedAt: Date = Date()) {
        self.key = key
        self.granted = granted
        self.grantedAt = grantedAt
    }
}
