import Foundation
import SwiftData

@Model
final class PersistedChatMessage {
    @Attribute(.unique) var id: UUID
    var role: String
    var text: String
    var createdAt: Date

    init(id: UUID, role: ChatRole, text: String, createdAt: Date) {
        self.id = id
        self.role = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    var asChatMessage: ChatMessage {
        ChatMessage(id: id, role: ChatRole(rawValue: role) ?? .assistant, text: text, createdAt: createdAt)
    }
}
