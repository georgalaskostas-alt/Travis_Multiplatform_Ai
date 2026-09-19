import Foundation

struct TravisCommand: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var source: CommandSource
    var status: CommandStatus
    var createdAt: Date
    var requiresApproval: Bool

    init(
        id: UUID = UUID(),
        text: String,
        source: CommandSource,
        status: CommandStatus = .queued,
        createdAt: Date = Date(),
        requiresApproval: Bool = true
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.requiresApproval = requiresApproval
    }
}

enum CommandSource: String, Codable, CaseIterable {
    case iphone
    case mac
    case voice
    case manual
}

enum CommandStatus: String, Codable, CaseIterable {
    case queued
    case awaitingApproval
    case approved
    case running
    case completed
    case failed
    case cancelled
}
