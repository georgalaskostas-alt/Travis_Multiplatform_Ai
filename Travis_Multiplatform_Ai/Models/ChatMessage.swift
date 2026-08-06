import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    /// Groups messages into a conversational "session" — see
    /// `TRAVISAppState`'s 12-hour gap rule for how this is assigned.
    var sessionId: UUID

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = Date(),
        sessionId: UUID
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sessionId = sessionId
    }
}

enum ChatRole: String, Codable, CaseIterable {
    case user
    case assistant
}
