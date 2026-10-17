import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    /// Groups messages into a conversational "session" — see
    /// `TRAVISAppState.startNewSession()` for when a new one is assigned.
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

extension Array where Element == ChatMessage {
    /// Compact "role: text" transcript, suitable for injecting into an AI
    /// classification prompt as short-term conversational context so
    /// references like "αυτό"/"σχετικά"/"συνέχισε" resolve correctly.
    /// Callers are expected to have already limited this to a reasonable
    /// recent window — this doesn't truncate on its own.
    var promptTranscript: String {
        map { "\($0.role == .user ? "Χρήστης" : "TRAVIS"): \($0.text)" }.joined(separator: "\n")
    }
}
