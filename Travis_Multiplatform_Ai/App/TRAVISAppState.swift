import Foundation
import Observation

@MainActor
@Observable
final class TRAVISAppState {
    var selectedSidebarItem: SidebarItem = .chat
    var chatInput: String = ""
    var chatMessages: [ChatMessage] = []
    var pendingCommands: [TravisCommand] = []
    var activeTasks: [TravisTask] = []
    var permissions: [TravisPermission] = []

    var assistantName: String = "TRAVIS"
    var preferredLanguage: AppLanguage = .greek
    var currentDeviceState: DeviceState = .idle
    var isListening: Bool = false
    var isProcessing: Bool = false
    var isInternetEnabled: Bool = true
    var isBusy: Bool = false
    var lastResponseSummary: String = "Ready"

    let approvalGate: ApprovalGateService
    let orchestrator: AgentOrchestrator

    init() {
        let approvalGate = ApprovalGateService()
        self.approvalGate = approvalGate
        self.orchestrator = AgentOrchestrator(approvalGate: approvalGate)
    }

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
        lastResponseSummary = "Message queued"
    }

    func addAssistantMessage(_ text: String) {
        chatMessages.append(ChatMessage(role: .assistant, text: text))
    }

    func sendCommand(_ text: String, source: CommandSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let command = TravisCommand(text: trimmed, source: source, status: .awaitingApproval)
        pendingCommands.append(command)
        lastResponseSummary = "Εντολή σε αναμονή: \(trimmed)"

        Task {
            await orchestrator.route(trimmed)
        }
    }

    func approveCommand(at index: Int) {
        guard pendingCommands.indices.contains(index) else { return }
        pendingCommands[index].status = .approved
        lastResponseSummary = "Command approved"
    }

    func denyCommand(at index: Int) {
        guard pendingCommands.indices.contains(index) else { return }
        pendingCommands[index].status = .cancelled
        lastResponseSummary = "Command denied"
    }

    func togglePermissionEnabled(_ permission: TravisPermission) {
        guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }
        permissions[index].isEnabled.toggle()
    }

    func updatePermission(_ permission: TravisPermission, to policy: PermissionPolicy) {
        guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }
        permissions[index].policy = policy
    }

    func toggleListening() {
        isListening.toggle()
        currentDeviceState = isListening ? .listening : .idle
    }

    func updateDeviceState(_ newState: DeviceState) {
        currentDeviceState = newState
    }
}
