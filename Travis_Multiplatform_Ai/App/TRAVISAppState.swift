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

    var anthropicAPIKey: String = "" {
        didSet {
            if anthropicAPIKey.isEmpty {
                KeychainService.shared.deleteAnthropicAPIKey()
            } else {
                KeychainService.shared.saveAnthropicAPIKey(anthropicAPIKey)
            }
        }
    }

    let approvalGate: ApprovalGateService
    let orchestrator: AgentOrchestrator

    init() {
        let approvalGate = ApprovalGateService()
        let orchestrator = AgentOrchestrator(approvalGate: approvalGate)
        self.approvalGate = approvalGate
        self.orchestrator = orchestrator

        orchestrator.register(TextTaskCapability())
        orchestrator.onAssistantMessage = { [weak self] text in
            self?.addAssistantMessage(text)
        }

        if let savedKey = KeychainService.shared.anthropicAPIKey {
            self.anthropicAPIKey = savedKey
        }

        bootstrap()
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

        chatMessages = PersistenceService.shared.loadChatMessages()

        let restoredActions = PersistenceService.shared.loadProposedActions()
        approvalGate.restore(pending: restoredActions.pending, history: restoredActions.history)
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let message = ChatMessage(role: .user, text: text)
        chatMessages.append(message)
        PersistenceService.shared.saveChatMessage(message)
        chatInput = ""
        lastResponseSummary = "Message queued"
    }

    func addAssistantMessage(_ text: String) {
        let message = ChatMessage(role: .assistant, text: text)
        chatMessages.append(message)
        PersistenceService.shared.saveChatMessage(message)
    }

    func sendCommand(_ text: String, source: CommandSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, text: trimmed)
        chatMessages.append(userMessage)
        PersistenceService.shared.saveChatMessage(userMessage)

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

    func saveGeneratedText(_ text: String, filename: String? = nil, capabilityId: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            addAssistantMessage("Δεν ήταν δυνατή η αποθήκευση του αρχείου.")
            return
        }

        let resolvedFilename = filename ?? "travis-text-\(Int(Date().timeIntervalSince1970)).txt"
        let fileURL = documentsURL.appendingPathComponent(resolvedFilename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            PersistenceService.shared.saveFile(filename: resolvedFilename, path: fileURL.path, capabilityId: capabilityId)
            addAssistantMessage("Το κείμενο αποθηκεύτηκε: \(fileURL.path)")
        } catch {
            addAssistantMessage("Αποτυχία αποθήκευσης: \(error.localizedDescription)")
        }
    }
}
