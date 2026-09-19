import Foundation
import SwiftData

@MainActor
extension PersistenceService {
    /// Permanently removes every persisted message that belongs to one chat
    /// session. ChatSession is derived from PersistedChatMessage rows, so
    /// once these are deleted the session disappears from history.
    @discardableResult
    func deleteChatSession(_ sessionId: UUID) throws -> Int {
        let context = container.mainContext
        let targetSessionId = sessionId
        let descriptor = FetchDescriptor<PersistedChatMessage>(
            predicate: #Predicate { $0.sessionId == targetSessionId }
        )
        let storedMessages = try context.fetch(descriptor)

        for message in storedMessages {
            context.delete(message)
        }

        try context.save()
        return storedMessages.count
    }
}
