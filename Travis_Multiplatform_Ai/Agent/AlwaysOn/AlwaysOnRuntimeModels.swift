import Foundation

enum AlwaysOnJobKind: String, Codable, CaseIterable { case mission, watcher, tradingPaper, tradingTestnet }
enum AlwaysOnJobState: String, Codable { case scheduled, running, sleeping, blocked, paused, failed, stopped }

struct AlwaysOnJob: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var kind: AlwaysOnJobKind
    var state: AlwaysOnJobState
    var createdAt: Date
    var updatedAt: Date
    var nextRunAt: Date?
    var cadenceSeconds: TimeInterval?
    var payload: String
    var lastError: String?
    var consecutiveFailures: Int
    var isEnabled: Bool

    init(id: UUID = UUID(), title: String, kind: AlwaysOnJobKind, state: AlwaysOnJobState = .scheduled, createdAt: Date = Date(), updatedAt: Date = Date(), nextRunAt: Date? = nil, cadenceSeconds: TimeInterval? = nil, payload: String, lastError: String? = nil, consecutiveFailures: Int = 0, isEnabled: Bool = true) {
        self.id=id; self.title=title; self.kind=kind; self.state=state; self.createdAt=createdAt; self.updatedAt=updatedAt; self.nextRunAt=nextRunAt; self.cadenceSeconds=cadenceSeconds; self.payload=payload; self.lastError=lastError; self.consecutiveFailures=consecutiveFailures; self.isEnabled=isEnabled
    }
}

struct AlwaysOnHeartbeat: Codable, Equatable { var processID: Int32; var startedAt: Date; var lastBeatAt: Date; var activeJobs: Int; var version: Int = 1 }
