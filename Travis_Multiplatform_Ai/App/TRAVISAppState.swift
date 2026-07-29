import Foundation
import Observation

@Observable
final class TRAVISAppState {
    var selectedSidebarItem: SidebarItem = .chat
    var chatInput: String = ""
    var chatMessages: [ChatMessage] = []
    var pendingCommands: [TravisCommand] = []
    var activeTasks: [TravisTask] = []
    var permissions: [TravisPermission] = []
    var deviceState: DeviceState = .defaultState

    var isBusy: Bool = false
    var lastStatusMessage: String = "Ready"

    func bootstrap() {
        if permissions.isEmpty {
            permissions = TravisPermission.defaultPermissions
        }

        if activeTasks.isEmpty {
            activeTasks = [
                TravisTask(title: "Connect services", details: "Wire AI, sync, and execution layers.", status: .pending, priority: .high),
                TravisTask(title: "Prepare permissions", details: "Set user approval rules for sensitive actions.", status: .pending, priority: .medium)
            ]
        }
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        chatMessages.append(ChatMessage(role: .user, text: text))
        chatInput = ""
        lastStatusMessage = "Message queued"
    }

    func addAssistantMessage(_ text: String) {
        chatMessages.append(ChatMessage(role: .assistant, text: text))
    }

    func queueCommand(_ text: String) {
        let command = TravisCommand(text: text, status: .pendingApproval)
        pendingCommands.append(command)
        lastStatusMessage = "Command queued"
    }

    func approveCommand(at index: Int) {
        guard pendingCommands.indices.contains(index) else { return }
        pendingCommands[index].status = .approved
        lastStatusMessage = "Command approved"
    }

    func denyCommand(at index: Int) {
        guard pendingCommands.indices.contains(index) else { return }
        pendingCommands[index].status = .denied
        lastStatusMessage = "Command denied"
    }

    func setPermission(_ capability: TravisCapability, enabled: Bool, policy: PermissionPolicy) {
        if let index = permissions.firstIndex(where: { $0.capability == capability }) {
            permissions[index].isEnabled = enabled
            permissions[index].policy = policy
        } else {
            permissions.append(TravisPermission(capability: capability, isEnabled: enabled, policy: policy))
        }
    }

    func updateDeviceState(_ newState: DeviceState) {
        deviceState = newState
    }
}
