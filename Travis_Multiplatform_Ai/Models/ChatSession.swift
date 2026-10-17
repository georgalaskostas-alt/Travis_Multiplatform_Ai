import Foundation

/// A derived (not separately persisted) grouping of `ChatMessage`s that
/// share a `sessionId` — the unit shown in the "Ιστορικό" list and the one
/// `SessionRecallService` resolves natural-language references against.
struct ChatSession: Identifiable, Hashable {
    let id: UUID
    let messages: [ChatMessage]

    var startedAt: Date { messages.first?.createdAt ?? Date() }
    var endedAt: Date { messages.last?.createdAt ?? Date() }

    var preview: String {
        messages.first(where: { $0.role == .user })?.text ?? messages.first?.text ?? ""
    }
}
