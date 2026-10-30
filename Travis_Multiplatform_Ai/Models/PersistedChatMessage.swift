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

/// Canonical destructive operations for persisted chat history.
///
/// A conversation is not stored as a separate database row; it is the group
/// of `PersistedChatMessage` rows sharing one `sessionId`. Deleting a session
/// therefore means deleting every persisted message with that id and saving
/// the SwiftData context once.
@MainActor
enum ChatHistoryStore {
    static func deleteSession(_ sessionId: UUID) throws {
        let targetSessionId = sessionId
        let context = PersistenceService.shared.container.mainContext
        let descriptor = FetchDescriptor<PersistedChatMessage>(
            predicate: #Predicate { message in
                message.sessionId == targetSessionId
            }
        )

        let messages = try context.fetch(descriptor)
        for message in messages {
            context.delete(message)
        }
        try context.save()
    }
}
