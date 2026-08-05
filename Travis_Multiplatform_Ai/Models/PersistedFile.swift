import Foundation
import SwiftData

/// Record of a file the app created on disk, so future capability calls
/// (e.g. "does a file with this name already exist?") can check history
/// without re-scanning the filesystem.
@Model
final class PersistedFile {
    @Attribute(.unique) var id: UUID
    var filename: String
    var path: String
    var createdAt: Date
    var capabilityId: String

    init(id: UUID = UUID(), filename: String, path: String, createdAt: Date = Date(), capabilityId: String) {
        self.id = id
        self.filename = filename
        self.path = path
        self.createdAt = createdAt
        self.capabilityId = capabilityId
    }
}
