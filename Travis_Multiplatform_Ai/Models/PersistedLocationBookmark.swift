import Foundation
import SwiftData

/// A security-scoped bookmark for a folder outside the app's sandbox
/// container that the user has granted access to via NSOpenPanel (macOS
/// only), keyed by the normalized free-text location the AI extracted
/// (e.g. "desktop"). Persisting this means the picker only needs to be
/// shown once per distinct location, not on every restart.
@Model
final class PersistedLocationBookmark {
    @Attribute(.unique) var locationKey: String
    var bookmarkData: Data
    var createdAt: Date

    init(locationKey: String, bookmarkData: Data, createdAt: Date = Date()) {
        self.locationKey = locationKey
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }
}
