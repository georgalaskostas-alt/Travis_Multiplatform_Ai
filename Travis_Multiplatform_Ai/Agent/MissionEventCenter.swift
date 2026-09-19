import Foundation
import Observation

struct MissionEvent: Identifiable, Equatable {
    enum Kind: String { case completed, failed, warning, info }
    var id = UUID()
    var taskId: UUID?
    var kind: Kind
    var title: String
    var message: String
    var createdAt = Date()
    var isRead = false
}

@MainActor
@Observable
final class MissionEventCenter {
    static let shared = MissionEventCenter()
    private(set) var events: [MissionEvent] = []

    var unreadCount: Int { events.filter { !$0.isRead }.count }

    func publish(taskId: UUID?, kind: MissionEvent.Kind, title: String, message: String) {
        events.insert(MissionEvent(taskId: taskId, kind: kind, title: title, message: message), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }

    func markAllRead() {
        for index in events.indices { events[index].isRead = true }
    }

    func removeAll() { events.removeAll() }
}
