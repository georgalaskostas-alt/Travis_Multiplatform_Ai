import Foundation

/// Durable local mirror for cloud-control state. The remote transport is deliberately protocol-driven:
/// credentials stay outside source control and a Supabase-backed implementation can be injected at runtime.
actor TravisControlPlaneStore: TravisControlPlaneTransport {
    static let shared = TravisControlPlaneStore()
    private var devices: [UUID: TravisDevicePresence] = [:]
    private var commands: [UUID: TravisControlCommand] = [:]
    private var snapshots: [UUID: TravisMissionCloudSnapshot] = [:]

    func register(device: TravisDevicePresence) async throws { devices[device.id] = device }
    func heartbeat(device: TravisDevicePresence) async throws { devices[device.id] = device }
    func enqueue(_ command: TravisControlCommand) async throws { commands[command.id] = command }
    func pendingCommands(deviceID: UUID) async throws -> [TravisControlCommand] { commands.values.filter { $0.deviceID == deviceID && $0.status == .queued && !$0.isExpired }.sorted { $0.createdAt < $1.createdAt } }
    func acknowledge(commandID: UUID) async throws { guard var value = commands[commandID] else { return }; value.status = .acknowledged; value.acknowledgedAt = .now; commands[commandID] = value }
    func complete(commandID: UUID, result: String) async throws { guard var value = commands[commandID] else { return }; value.status = .completed; value.completedAt = .now; value.result = result; commands[commandID] = value }
    func publish(snapshot: TravisMissionCloudSnapshot) async throws { snapshots[snapshot.taskID] = snapshot }
}
