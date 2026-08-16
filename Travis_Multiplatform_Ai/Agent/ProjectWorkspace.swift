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
    }
}

struct ProjectDecision: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var rationale: String?
    var createdAt: Date
    init(id: UUID = UUID(), text: String, rationale: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.rationale = rationale; self.createdAt = createdAt
    }
}

struct ProjectNote: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
    }
}
