import Foundation
import SwiftData

/// Record of a file the app created on disk, so future capability calls
/// (e.g. "does a file with this name already exist?") can check history
/// without re-scanning the filesystem. `.unique` is gone and every
/// non-optional property has an inline default — required for
/// CloudKit-backed SwiftData, see `PersistedChatMessage`.
@Model
final class PersistedFile {
    var id: UUID = UUID()
    var filename: String = ""
    var path: String = ""
    var createdAt: Date = Date()
    var capabilityId: String = ""

    init(id: UUID = UUID(), filename: String, path: String, createdAt: Date = Date(), capabilityId: String) {
        self.id = id
        self.filename = filename
        self.path = path
        self.createdAt = createdAt
        self.capabilityId = capabilityId
    }
}
