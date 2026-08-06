import Foundation
import SwiftData

/// A standing permission the user grants once and TRAVIS remembers until
/// explicitly revoked — e.g. "you can save files" today, a trading
/// standing mandate later. Deliberately generic: callers own their own
/// key strings (e.g. "file_save"), so unrelated standing permissions can
/// coexist without this model knowing anything about what they gate.
@Model
final class StandingPermission {
    @Attribute(.unique) var key: String
    var granted: Bool
    var grantedAt: Date

    init(key: String, granted: Bool, grantedAt: Date = Date()) {
        self.key = key
        self.granted = granted
        self.grantedAt = grantedAt
    }
}
