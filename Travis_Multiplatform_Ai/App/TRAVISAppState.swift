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

    /// The session new messages are actually appended to right now.
    private(set) var currentSessionId: UUID = UUID()
    /// The session currently shown in `chatMessages` — equal to
    /// `currentSessionId` unless the user is browsing a past one via
    /// `viewSession(_:)`.
    private(set) var viewedSessionId: UUID = UUID()

    init() {
        let approvalGate = ApprovalGateService()
        let orchestrator = AgentOrchestrator(approvalGate: approvalGate)
        self.approvalGate = approvalGate
        self.orchestrator = orchestrator

        orchestrator.register(TextTaskCapability())
        orchestrator.register(CryptoTradingCapability())
        orchestrator.onAssistantMessage = { [weak self] text in
            self?.addAssistantMessage(text)
        }
        orchestrator.onSessionRecall = { [weak self] sessionId in
            self?.viewSession(sessionId)
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

        // Every cold launch always starts on a fresh, empty session — see
        // `startNewSession()`. Full history stays persisted and reachable
        // via the "Ιστορικό" tab and voice/text recall regardless.
        startNewSession()

        let restoredActions = PersistenceService.shared.loadProposedActions()
        approvalGate.restore(pending: restoredActions.pending, history: restoredActions.history)

        refreshTradingMandates()
    }

    /// Starts a brand-new, empty session and displays it — called on
    /// bootstrap (cold launch) and whenever the app returns to the
    /// foreground (see the `scenePhase` watcher in the App entry point).
    /// Does not touch or delete any previously persisted session.
    func startNewSession() {
        currentSessionId = UUID()
        viewedSessionId = currentSessionId
        chatMessages = []
    }

    /// Past sessions available to browse — the live one is excluded since
    /// it's already what `ChatView` shows by default.
    var pastSessions: [ChatSession] {
        PersistenceService.shared.loadChatSessions().filter { $0.id != currentSessionId }
    }

    /// Switches what `chatMessages` displays to a past session, without
    /// touching the live session — new messages still land there (see
    /// `appendMessage`), which snaps the view back automatically.
    func viewSession(_ sessionId: UUID) {
        guard sessionId != viewedSessionId else { return }
        viewedSessionId = sessionId
        chatMessages = PersistenceService.shared.loadChatMessages().filter { $0.sessionId == sessionId }
    }

    func returnToCurrentSession() {
        guard viewedSessionId != currentSessionId else { return }
        viewedSessionId = currentSessionId
        chatMessages = PersistenceService.shared.loadChatMessages().filter { $0.sessionId == currentSessionId }
    }

    /// Tags, persists, and displays a new message under the live session
    /// (`currentSessionId` — new sessions are only started by
    /// `startNewSession()`, not by inter-message timing), and snaps the
    /// view back to live if the user had been browsing a past session.
    @discardableResult
    private func appendMessage(role: ChatRole, text: String) -> ChatMessage {
        let message = ChatMessage(role: role, text: text, sessionId: currentSessionId)
        PersistenceService.shared.saveChatMessage(message)

        if viewedSessionId == currentSessionId {
            chatMessages.append(message)
        } else {
            viewedSessionId = currentSessionId
            chatMessages = PersistenceService.shared.loadChatMessages().filter { $0.sessionId == currentSessionId }
        }

        return message
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        appendMessage(role: .user, text: text)
        chatInput = ""
        lastResponseSummary = "Message queued"
    }

    func addAssistantMessage(_ text: String) {
        appendMessage(role: .assistant, text: text)
    }

    func sendCommand(_ text: String, source: CommandSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendMessage(role: .user, text: trimmed)

        let command = TravisCommand(text: trimmed, source: source, status: .awaitingApproval)
        pendingCommands.append(command)
        lastResponseSummary = "Εντολή σε αναμονή: \(trimmed)"

        let liveSessionId = currentSessionId
        Task {
            await orchestrator.route(trimmed, liveSessionId: liveSessionId)
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

    /// Active crypto trading standing mandates ("trading_XRP", "trading_SOL",
    /// ...) — refreshed explicitly (see `refreshTradingMandates()`) rather
    /// than computed on read, since it's backed by SwiftData model
    /// instances mutated outside TRAVISAppState's own observed state.
    var tradingMandates: [StandingPermission] = []

    func refreshTradingMandates() {
        tradingMandates = PersistenceService.shared.standingPermissions(withKeyPrefix: "trading_").filter { $0.granted }
    }

    func revokeTradingMandate(_ mandate: StandingPermission) {
        PersistenceService.shared.setPermission(mandate.key, granted: false)
        refreshTradingMandates()
    }

    func saveGeneratedText(_ text: String, filename: String? = nil, location: String? = nil, capabilityId: String) {
        guard let resolved = FileLocationService.shared.resolveSaveDirectory(for: location) else {
            addAssistantMessage("Δεν ήταν δυνατή η αποθήκευση του αρχείου — δεν δόθηκε πρόσβαση στον φάκελο.")
            return
        }
        defer { resolved.stopAccessing() }

        let resolvedFilename = filename ?? "travis-text-\(Int(Date().timeIntervalSince1970)).txt"
        let fileURL = resolved.url.appendingPathComponent(resolvedFilename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            PersistenceService.shared.saveFile(filename: resolvedFilename, path: fileURL.path, capabilityId: capabilityId)
            addAssistantMessage("Το κείμενο αποθηκεύτηκε: \(fileURL.path)")
        } catch {
            addAssistantMessage("Αποτυχία αποθήκευσης: \(error.localizedDescription)")
        }
    }
}
