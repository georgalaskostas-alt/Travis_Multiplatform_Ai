import Foundation

enum DeferredWorkStatus: String, Codable, CaseIterable, Hashable {
    case scheduled
    case running
    case completed
    case failed
    case cancelled
}

enum DeferredWorkRecurrence: Codable, Hashable {
    case none
    case interval(seconds: TimeInterval)

    private enum CodingKeys: String, CodingKey { case kind, seconds }
    private enum Kind: String, Codable { case none, interval }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .interval:
            self = .interval(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .interval(let seconds):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        }
    }
}

struct DeferredWorkItem: Identifiable, Codable, Hashable {
    let id: UUID
    var taskId: UUID
    var title: String
    var runAt: Date
    var recurrence: DeferredWorkRecurrence
    var status: DeferredWorkStatus
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?
    var runCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        taskId: UUID,
        title: String,
        runAt: Date,
        recurrence: DeferredWorkRecurrence = .none,
        status: DeferredWorkStatus = .scheduled,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        runCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.runAt = runAt
        self.recurrence = recurrence
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt ?? runAt
        self.runCount = runCount
        self.lastError = lastError
    }

    var effectiveRunAt: Date { nextRunAt ?? runAt }
    var isRecurring: Bool {
        if case .interval = recurrence { return true }
        return false
    }
}
