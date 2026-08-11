import Foundation
import SwiftData

/// `.unique` and non-defaulted properties are both disallowed once
/// CloudKit sync is enabled (see `PersistenceService.makeContainer`) —
/// CloudKit has no schema-level uniqueness constraint, and every
/// non-optional attribute needs an inline default so a partially
/// materialized CloudKit record still has a valid value.
@Model
final class PersistedChatMessage {
    var id: UUID = UUID()
    var role: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    var sessionId: UUID = UUID()

    init(id: UUID, role: ChatRole, text: String, createdAt: Date, sessionId: UUID) {
        self.id = id
        self.role = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.sessionId = sessionId
    }

    var asChatMessage: ChatMessage {
        ChatMessage(id: id, role: ChatRole(rawValue: role) ?? .assistant, text: text, createdAt: createdAt, sessionId: sessionId)
    }
}
