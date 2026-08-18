import Foundation

struct ProjectWorkspace: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable { case active, paused, completed, archived }

    let id: UUID
    var title: String
    var goal: String
    var summary: String
    var status: Status
    var createdAt: Date
    var updatedAt: Date
    var taskIds: [UUID]
    var decisions: [ProjectDecision]
    var notes: [ProjectNote]
    var artifactPaths: [String]

    /// Optional for backwards-compatible decoding of older project snapshots.
    var sessionIds: [UUID]?
    var goals: [ProjectGoal]?
    var pendingItems: [ProjectPendingItem]?
    var deliverables: [ProjectDeliverable]?

    init(id: UUID = UUID(), title: String, goal: String, summary: String = "") {
        self.id = id
        self.title = title
        self.goal = goal
        self.summary = summary
        self.status = .active
        self.createdAt = Date()
        self.updatedAt = Date()
        self.taskIds = []
        self.decisions = []
        self.notes = []
        self.artifactPaths = []
        self.sessionIds = []
        self.goals = [ProjectGoal(text: goal, status: .active)]
        self.pendingItems = []
        self.deliverables = []
    }
}

struct ProjectDecision: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var rationale: String?
    var createdAt: Date

    init(id: UUID = UUID(), text: String, rationale: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.rationale = rationale
        self.createdAt = createdAt
    }
}

struct ProjectNote: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

struct ProjectGoal: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable { case active, completed, cancelled }
    let id: UUID
    var text: String
    var status: Status
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), text: String, status: Status = .active, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct ProjectPendingItem: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable { case pending, completed, cancelled }
    let id: UUID
    var text: String
    var status: Status
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), text: String, status: Status = .pending, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct ProjectDeliverable: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Hashable { case planned, ready, delivered, cancelled }
    let id: UUID
    var name: String
    var path: String?
    var status: Status
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), name: String, path: String? = nil, status: Status = .planned, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
