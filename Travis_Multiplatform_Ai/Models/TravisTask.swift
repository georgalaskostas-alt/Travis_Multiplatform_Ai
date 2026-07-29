import Foundation

struct TravisTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var details: String
    var status: TravisTaskStatus
    var priority: TravisTaskPriority
    var createdAt: Date
    var dueDate: Date?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        status: TravisTaskStatus = .pending,
        priority: TravisTaskPriority = .medium,
        createdAt: Date = Date(),
        dueDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.dueDate = dueDate
    }
}

enum TravisTaskStatus: String, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

enum TravisTaskPriority: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

let sampleTasks: [TravisTask] = [
    TravisTask(title: "Παρακολούθηση μετοχών", details: "Έλεγχος alerts για watchlist", status: .running, priority: .high),
    TravisTask(title: "Inbox summary", details: "Σύνοψη σημαντικών emails", status: .pending, priority: .medium),
    TravisTask(title: "Xcode agent", details: "Προετοιμασία νέου iPhone app flow", status: .pending, priority: .high)
]
