import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

enum ChatRole: String, Codable, CaseIterable {
    case user
    case assistant
}
