import Foundation
import SwiftData

/// A security-scoped bookmark for a folder outside the app's sandbox
/// container that the user has granted access to via NSOpenPanel (macOS
/// only), keyed by the normalized free-text location the AI extracted
/// (e.g. "desktop"). Persisting this means the picker only needs to be
/// shown once per distinct location, not on every restart.
///
/// `.unique` on `locationKey` is gone and every non-optional property
/// has an inline default — required for CloudKit-backed SwiftData (see
/// `PersistedChatMessage`). Without a schema-level uniqueness
/// constraint, two devices creating a bookmark for the same
/// `locationKey` while offline can both sync up as separate rows —
/// `PersistenceService.deduplicateLocationBookmarks()` cleans those up
/// after launch, keeping the most recent.
@Model
final class PersistedLocationBookmark {
    var locationKey: String = ""
    var bookmarkData: Data = Data()
    var createdAt: Date = Date()

    init(locationKey: String, bookmarkData: Data, createdAt: Date = Date()) {
        self.locationKey = locationKey
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }
}
