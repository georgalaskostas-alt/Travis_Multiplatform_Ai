import Foundation

enum TravisControlCommandType: String, Codable, Sendable { case mission, pauseTask, resumeTask, cancelTask, deleteTask, deleteFinished, killSwitch, requestStatus }
enum TravisControlCommandStatus: String, Codable, Sendable { case queued, acknowledged, executing, completed, failed, expired }

struct TravisControlCommand: Codable, Sendable, Identifiable {
    let id: UUID
    let deviceID: UUID
    let type: TravisControlCommandType
    let payload: [String: String]
    let createdAt: Date
    let expiresAt: Date
    let nonce: UUID
    var status: TravisControlCommandStatus
    var acknowledgedAt: Date?
    var completedAt: Date?
    var result: String?

    var isExpired: Bool { Date() >= expiresAt }
}

struct TravisDevicePresence: Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var platform: String
    var workerOnline: Bool
    var guiOnline: Bool
    var lanLinkOnline: Bool
    var cloudLinkOnline: Bool
    var lastHeartbeatAt: Date
}

struct TravisMissionCloudSnapshot: Codable, Sendable, Identifiable {
    let id: UUID
    let deviceID: UUID
    let taskID: UUID
    let status: String
    let progress: Double
    let summary: String
    let updatedAt: Date
}

protocol TravisControlPlaneTransport: Sendable {
    func register(device: TravisDevicePresence) async throws
    func heartbeat(device: TravisDevicePresence) async throws
    func enqueue(_ command: TravisControlCommand) async throws
    func pendingCommands(deviceID: UUID) async throws -> [TravisControlCommand]
    func acknowledge(commandID: UUID) async throws
    func complete(commandID: UUID, result: String) async throws
    func publish(snapshot: TravisMissionCloudSnapshot) async throws
}
