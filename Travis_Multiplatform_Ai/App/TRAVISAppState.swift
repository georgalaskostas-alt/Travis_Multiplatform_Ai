import Foundation
import Observation

@MainActor
@Observable
final class TRAVISAppState {
    // MARK: - UI State

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

    // MARK: - API Keys

    var anthropicAPIKey: String = "" {
        didSet { anthropicAPIKey.isEmpty ? KeychainService.shared.deleteAnthropicAPIKey() : KeychainService.shared.saveAnthropicAPIKey(anthropicAPIKey) }
    }
    var binanceTestnetAPIKey: String = "" {
        didSet { binanceTestnetAPIKey.isEmpty ? KeychainService.shared.deleteBinanceTestnetAPIKey() : KeychainService.shared.saveBinanceTestnetAPIKey(binanceTestnetAPIKey) }
    }
    var binanceTestnetAPISecret: String = "" {
        didSet { binanceTestnetAPISecret.isEmpty ? KeychainService.shared.deleteBinanceTestnetAPISecret() : KeychainService.shared.saveBinanceTestnetAPISecret(binanceTestnetAPISecret) }
    }

    // MARK: - Agent Infrastructure

    let approvalGate: ApprovalGateService
    let orchestrator: AgentOrchestrator
    let taskRuntime: AgentTaskRuntime
    let taskExecutor: AgentTaskExecutor

    // MARK: - Sessions

    private(set) var currentSessionId: UUID = UUID()
    private(set) var viewedSessionId: UUID = UUID()

    // MARK: - Init

    init() {
        let approvalGate = ApprovalGateService()
        let orchestrator = AgentOrchestrator(approvalGate: approvalGate)
        let taskRuntime = AgentTaskRuntime()
        let taskExecutor = AgentTaskExecutor(runtime: taskRuntime, orchestrator: orchestrator, approvalGate: approvalGate)

        self.approvalGate = approvalGate
        self.orchestrator = orchestrator
        self.taskRuntime = taskRuntime
        self.taskExecutor = taskExecutor

        let cryptoTradingCapability = CryptoTradingCapability()
        let filesystemOperationsCapability = FilesystemOperationsCapability()
        let advancedFilesystemCapability = AdvancedFilesystemCapability()
        let localProductivityCapability = LocalProductivityCapability()
        let localAutomationCapability = LocalAutomationCapability()
        let localDocumentCapability = LocalDocumentCapability()
        let localFileSearchCapability = LocalFileSearchCapability()

        orchestrator.register(TextTaskCapability())
        orchestrator.register(cryptoTradingCapability)
        orchestrator.register(SelfImprovementCapability())
        orchestrator.register(filesystemOperationsCapability)
        orchestrator.register(advancedFilesystemCapability)
        orchestrator.register(localProductivityCapability)
        orchestrator.register(localAutomationCapability)
        orchestrator.register(localDocumentCapability)
        orchestrator.register(localFileSearchCapability)

        orchestrator.onAssistantMessage = { [weak self] text in self?.addAssistantMessage(text) }
        orchestrator.onSessionRecall = { [weak self] sessionId in self?.viewSession(sessionId) }
        taskExecutor.onProgress = { [weak self] text in self?.addAssistantMessage(text) }
        cryptoTradingCapability.onTestnetExecutionUpdate = { [weak self] text in self?.addAssistantMessage(text) }
        filesystemOperationsCapability.onExecutionUpdate = { [weak self] text in self?.addAssistantMessage(text) }
        advancedFilesystemCapability.onExecutionUpdate = { [weak self] text in self?.addAssistantMessage(text) }
        localProductivityCapability.onExecutionUpdate = { [weak self] text in self?.addAssistantMessage(text) }
        localAutomationCapability.onExecutionUpdate = { [weak self] text in self?.addAssistantMessage(text) }

        SpeechRecognitionService.shared.onFinalTranscript = { [weak self] text in self?.sendCommand(text, source: .voice) }

        if let savedKey = KeychainService.shared.anthropicAPIKey { self.anthropicAPIKey = savedKey }
        if let savedTestnetKey = KeychainService.shared.binanceTestnetAPIKey { self.binanceTestnetAPIKey = savedTestnetKey }
        if let savedTestnetSecret = KeychainService.shared.binanceTestnetAPISecret { self.binanceTestnetAPISecret = savedTestnetSecret }
        bootstrap()
    }

    // MARK: - Bootstrap

    func bootstrap() {
        if permissions.isEmpty { permissions = TravisPermission.defaultPermissions }
        if activeTasks.isEmpty {
            activeTasks = [
                TravisTask(title: "Connect services", details: "Wire AI, sync, and execution layers.", status: .pending, priority: .high),
                TravisTask(title: "Prepare permissions", details: "Set user approval rules for sensitive actions.", status: .pending, priority: .medium)
            ]
        }
        startNewSession()
        let restoredActions = PersistenceService.shared.loadProposedActions()
        approvalGate.restore(pending: restoredActions.pending, history: restoredActions.history)
        refreshTradingMandates()
    }

    // MARK: - Sessions

    func startNewSession() { currentSessionId = UUID(); viewedSessionId = currentSessionId; chatMessages = [] }
    var pastSessions: [ChatSession] { PersistenceService.shared.loadChatSessions().filter { $0.id != currentSessionId } }
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

    // MARK: - Messages

    @discardableResult
    func appendMessage(role: ChatRole, text: String) -> ChatMessage {
        let message = ChatMessage(role: role, text: text, sessionId: currentSessionId)
        PersistenceService.shared.saveChatMessage(message)
        if viewedSessionId == currentSessionId { chatMessages.append(message) }
        else {
            viewedSessionId = currentSessionId
            chatMessages = PersistenceService.shared.loadChatMessages().filter { $0.sessionId == currentSessionId }
        }
        return message
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatInput = ""
        sendCommand(text, source: .manual)
    }

    func addAssistantMessage(_ text: String) {
        appendMessage(role: .assistant, text: text)
        if isListening {
            SpeechService.shared.speak(text, language: preferredLanguage) { [weak self] in
                guard let self, self.isListening else { return }
                SpeechRecognitionService.shared.start(language: self.preferredLanguage)
            }
        }
    }

    // MARK: - Command Approval

    func approveCommand(at index: Int) { guard pendingCommands.indices.contains(index) else { return }; pendingCommands[index].status = .approved; lastResponseSummary = "Command approved" }
    func denyCommand(at index: Int) { guard pendingCommands.indices.contains(index) else { return }; pendingCommands[index].status = .cancelled; lastResponseSummary = "Command denied" }

    // MARK: - Permissions

    func togglePermissionEnabled(_ permission: TravisPermission) { guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }; permissions[index].isEnabled.toggle() }
    func updatePermission(_ permission: TravisPermission, to policy: PermissionPolicy) { guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }; permissions[index].policy = policy }

    // MARK: - Voice

    func toggleListening() {
        isListening.toggle(); currentDeviceState = isListening ? .listening : .idle
        if isListening { SpeechRecognitionService.shared.start(language: preferredLanguage) }
        else { SpeechService.shared.stopSpeaking(); SpeechRecognitionService.shared.stop() }
    }
    func updateDeviceState(_ newState: DeviceState) { currentDeviceState = newState }

    // MARK: - Trading Mandates

    var tradingMandates: [StandingPermission] = []
    func refreshTradingMandates() { tradingMandates = PersistenceService.shared.standingPermissions(withKeyPrefix: "trading_").filter { $0.granted } }
    func revokeTradingMandate(_ mandate: StandingPermission) { PersistenceService.shared.setPermission(mandate.key, granted: false); refreshTradingMandates() }

    // MARK: - Generated Files

    func saveGeneratedText(_ text: String, filename: String? = nil, location: String? = nil, capabilityId: String) {
        guard let resolved = FileLocationService.shared.resolveSaveDirectory(for: location) else {
            let message = "Δεν ήταν δυνατή η αποθήκευση του αρχείου — δεν δόθηκε πρόσβαση στον φάκελο."
            addAssistantMessage(message); lastResponseSummary = message; return
        }
        defer { resolved.stopAccessing() }
        let resolvedFilename = filename ?? "travis-text-\(Int(Date().timeIntervalSince1970)).txt"
        let fileURL = resolved.url.appendingPathComponent(resolvedFilename)
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            PersistenceService.shared.saveFile(filename: resolvedFilename, path: fileURL.path, capabilityId: capabilityId)
            addAssistantMessage("Το κείμενο αποθηκεύτηκε: \(fileURL.path)"); lastResponseSummary = "Αποθηκεύτηκε: \(resolvedFilename)"
        } catch {
            let message = "Αποτυχία αποθήκευσης: \(error.localizedDescription)"; addAssistantMessage(message); lastResponseSummary = message
        }
    }
}
