import Foundation
import SwiftData

/// Local, on-device SwiftData persistence. `ModelContainer(for:)` with no
/// explicit configuration resolves to the app's Application Support
/// directory identically on iOS and macOS — no platform-specific setup
/// needed for the container to be usable from both. CloudKit sync is a
/// separate step for later, not wired in here.
@MainActor
final class PersistenceService {
    static let shared = PersistenceService()

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    private init() {
        do {
            container = try ModelContainer(
                for: PersistedChatMessage.self, PersistedProposedAction.self, PersistedFile.self, PersistedLocationBookmark.self, StandingPermission.self
            )
        } catch {
            fatalError("Δεν ήταν δυνατή η αρχικοποίηση του SwiftData ModelContainer: \(error)")
        }
    }

    // MARK: - Chat messages

    func loadChatMessages() -> [ChatMessage] {
        let descriptor = FetchDescriptor<PersistedChatMessage>(sortBy: [SortDescriptor(\.createdAt)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.map(\.asChatMessage)
    }

    func saveChatMessage(_ message: ChatMessage) {
        context.insert(PersistedChatMessage(id: message.id, role: message.role, text: message.text, createdAt: message.createdAt, sessionId: message.sessionId))
        try? context.save()
    }

    /// Groups all persisted messages by `sessionId`, most recently started
    /// first — the basis for both the "Ιστορικό" list and
    /// `SessionRecallService`'s date-based lookup.
    func loadChatSessions() -> [ChatSession] {
        let grouped = Dictionary(grouping: loadChatMessages(), by: \.sessionId)
        return grouped
            .map { ChatSession(id: $0.key, messages: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Proposed actions

    func loadProposedActions() -> (pending: [ProposedAction], history: [ProposedAction]) {
        let descriptor = FetchDescriptor<PersistedProposedAction>(sortBy: [SortDescriptor(\.createdAt)])
        let actions = ((try? context.fetch(descriptor)) ?? []).map(\.asProposedAction)
        return (actions.filter { $0.status == .pending }, actions.filter { $0.status != .pending })
    }

    func saveProposedAction(_ action: ProposedAction) {
        context.insert(PersistedProposedAction(from: action))
        try? context.save()
    }

    func updateProposedAction(_ action: ProposedAction) {
        let targetId = action.id
        let descriptor = FetchDescriptor<PersistedProposedAction>(
            predicate: #Predicate { $0.id == targetId }
        )

        guard let existing = try? context.fetch(descriptor).first else { return }
        existing.apply(action)
        try? context.save()
    }

    // MARK: - Files

    func loadFiles() -> [PersistedFile] {
        let descriptor = FetchDescriptor<PersistedFile>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fileExists(named filename: String) -> Bool {
        loadFiles().contains { $0.filename.caseInsensitiveCompare(filename) == .orderedSame }
    }

    func saveFile(filename: String, path: String, capabilityId: String) {
        context.insert(PersistedFile(filename: filename, path: path, capabilityId: capabilityId))
        try? context.save()
    }

    // MARK: - Location bookmarks

    func loadLocationBookmark(for key: String) -> Data? {
        let descriptor = FetchDescriptor<PersistedLocationBookmark>(
            predicate: #Predicate { $0.locationKey == key }
        )
        return (try? context.fetch(descriptor).first)?.bookmarkData
    }

    func saveLocationBookmark(key: String, data: Data) {
        if let existing = try? context.fetch(FetchDescriptor<PersistedLocationBookmark>(
            predicate: #Predicate { $0.locationKey == key }
        )).first {
            existing.bookmarkData = data
            existing.createdAt = Date()
        } else {
            context.insert(PersistedLocationBookmark(locationKey: key, bookmarkData: data))
        }
        try? context.save()
    }

    // MARK: - Standing permissions

    /// Generic "granted until revoked" gate, reusable for any future
    /// standing mandate (e.g. trading) beyond today's file-save permission.
    func isPermissionGranted(_ key: String) -> Bool {
        let descriptor = FetchDescriptor<StandingPermission>(predicate: #Predicate { $0.key == key })
        return (try? context.fetch(descriptor).first)?.granted ?? false
    }

    func setPermission(_ key: String, granted: Bool) {
        let descriptor = FetchDescriptor<StandingPermission>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.granted = granted
            existing.grantedAt = Date()
        } else {
            context.insert(StandingPermission(key: key, granted: granted))
        }
        try? context.save()
    }
}
