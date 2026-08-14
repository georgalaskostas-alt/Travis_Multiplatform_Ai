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
        didSet {
            if anthropicAPIKey.isEmpty {
                KeychainService.shared.deleteAnthropicAPIKey()
            } else {
                KeychainService.shared.saveAnthropicAPIKey(anthropicAPIKey)
            }
        }
    }

    /// Binance SPOT TESTNET credentials only — entirely separate Keychain
    /// entries from any future live-trading key (see `KeychainService`).
    /// Used exclusively by `BinanceTestnetTradingService`; never read for
    /// anything resembling a real account.
    var binanceTestnetAPIKey: String = "" {
        didSet {
            if binanceTestnetAPIKey.isEmpty {
                KeychainService.shared.deleteBinanceTestnetAPIKey()
            } else {
                KeychainService.shared.saveBinanceTestnetAPIKey(binanceTestnetAPIKey)
            }
        }
    }

    var binanceTestnetAPISecret: String = "" {
        didSet {
            if binanceTestnetAPISecret.isEmpty {
                KeychainService.shared.deleteBinanceTestnetAPISecret()
            } else {
                KeychainService.shared.saveBinanceTestnetAPISecret(binanceTestnetAPISecret)
            }
        }
    }

    // MARK: - Agent Infrastructure

    let approvalGate: ApprovalGateService
    let orchestrator: AgentOrchestrator

    /// Runtime for persistent, long-lived autonomous tasks.
    ///
    /// Planning and execution state are deliberately separated:
    ///
    /// TaskPlanner
    ///     ↓
    /// TaskPlan
    ///     ↓
    /// AgentTaskRuntime
    ///     ↓
    /// future AgentTaskExecutor
    ///
    /// The runtime owns deterministic task lifecycle state.
    let taskRuntime: AgentTaskRuntime

    /// Executes one validated runtime step through the existing capability
    /// system and verifies the result before completion.
    let taskExecutor: AgentTaskExecutor

    // MARK: - Sessions

    /// The session new messages are actually appended to right now.
    private(set) var currentSessionId: UUID = UUID()

    /// The session currently shown in `chatMessages` — equal to
    /// `currentSessionId` unless the user is browsing a past one via
    /// `viewSession(_:)`.
    private(set) var viewedSessionId: UUID = UUID()

    // MARK: - Init

    init() {

        let approvalGate = ApprovalGateService()
        let orchestrator = AgentOrchestrator(
            approvalGate: approvalGate
        )
        let taskRuntime = AgentTaskRuntime()
        let taskExecutor = AgentTaskExecutor(
            runtime: taskRuntime,
            orchestrator: orchestrator,
            approvalGate: approvalGate
        )

        self.approvalGate = approvalGate
        self.orchestrator = orchestrator
        self.taskRuntime = taskRuntime
        self.taskExecutor = taskExecutor

        let cryptoTradingCapability = CryptoTradingCapability()

        orchestrator.register(TextTaskCapability())
        orchestrator.register(cryptoTradingCapability)
        orchestrator.register(SelfImprovementCapability())

        orchestrator.onAssistantMessage = { [weak self] text in
            self?.addAssistantMessage(text)
        }

        orchestrator.onSessionRecall = { [weak self] sessionId in
            self?.viewSession(sessionId)
        }

        taskExecutor.onProgress = { [weak self] text in
            self?.addAssistantMessage(text)
        }

        // Testnet order execution happens asynchronously after Approve
        // (see CryptoTradingCapability.resolve) — this is how its result
        // (fill confirmation or failure) reaches the chat once it's back.
        cryptoTradingCapability.onTestnetExecutionUpdate = { [weak self] text in
            self?.addAssistantMessage(text)
        }

        SpeechRecognitionService.shared.onFinalTranscript = { [weak self] text in
            self?.sendCommand(text, source: .voice)
        }

        if let savedKey = KeychainService.shared.anthropicAPIKey {
            self.anthropicAPIKey = savedKey
        }

        if let savedTestnetKey = KeychainService.shared.binanceTestnetAPIKey {
            self.binanceTestnetAPIKey = savedTestnetKey
        }

        if let savedTestnetSecret = KeychainService.shared.binanceTestnetAPISecret {
            self.binanceTestnetAPISecret = savedTestnetSecret
        }

        bootstrap()
    }

    // MARK: - Bootstrap

    func bootstrap() {

        if permissions.isEmpty {
            permissions = TravisPermission.defaultPermissions
        }

        if activeTasks.isEmpty {
            activeTasks = [
                TravisTask(
                    title: "Connect services",
                    details: "Wire AI, sync, and execution layers.",
                    status: .pending,
                    priority: .high
                ),
                TravisTask(
                    title: "Prepare permissions",
                    details: "Set user approval rules for sensitive actions.",
                    status: .pending,
                    priority: .medium
                )
            ]
        }

        // Every cold launch always starts on a fresh, empty session.
        // Full history stays persisted and reachable via the history tab
        // and voice/text recall.
        startNewSession()

        let restoredActions =
            PersistenceService.shared.loadProposedActions()

        approvalGate.restore(
            pending: restoredActions.pending,
            history: restoredActions.history
        )

        refreshTradingMandates()
    }

    // MARK: - Sessions

    /// Starts a brand-new, empty session and displays it.
    ///
    /// Does not touch or delete any previously persisted session.
    func startNewSession() {
        currentSessionId = UUID()
        viewedSessionId = currentSessionId
        chatMessages = []
    }

    /// Past sessions available to browse — the live one is excluded since
    /// it's already what ChatView shows by default.
    var pastSessions: [ChatSession] {
        PersistenceService.shared
            .loadChatSessions()
            .filter {
                $0.id != currentSessionId
            }
    }

    /// Switches what chatMessages displays to a past session without
    /// touching the live session.
    func viewSession(_ sessionId: UUID) {

        guard sessionId != viewedSessionId else {
            return
        }

        viewedSessionId = sessionId

        chatMessages =
            PersistenceService.shared
                .loadChatMessages()
                .filter {
                    $0.sessionId == sessionId
                }
    }

    func returnToCurrentSession() {

        guard viewedSessionId != currentSessionId else {
            return
        }

        viewedSessionId = currentSessionId

        chatMessages =
            PersistenceService.shared
                .loadChatMessages()
                .filter {
                    $0.sessionId == currentSessionId
                }
    }

    // MARK: - Messages

    /// Tags, persists, and displays a new message under the live session.
    @discardableResult
    private func appendMessage(
        role: ChatRole,
        text: String
    ) -> ChatMessage {

        let message = ChatMessage(
            role: role,
            text: text,
            sessionId: currentSessionId
        )

        PersistenceService.shared.saveChatMessage(message)

        if viewedSessionId == currentSessionId {

            chatMessages.append(message)

        } else {

            viewedSessionId = currentSessionId

            chatMessages =
                PersistenceService.shared
                    .loadChatMessages()
                    .filter {
                        $0.sessionId == currentSessionId
                    }
        }

        return message
    }

    func sendChat() {

        let text =
            chatInput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !text.isEmpty else {
            return
        }

        appendMessage(
            role: .user,
            text: text
        )

        chatInput = ""
        lastResponseSummary = "Message queued"
    }

    func addAssistantMessage(_ text: String) {

        appendMessage(
            role: .assistant,
            text: text
        )

        // Recognition is already stopped by this point whenever it was
        // the thing that triggered this reply.
        //
        // Once the reply finishes, listening resumes automatically
        // if voice mode is still on.
        if isListening {

            SpeechService.shared.speak(
                text,
                language: preferredLanguage
            ) { [weak self] in

                guard
                    let self,
                    self.isListening
                else {
                    return
                }

                SpeechRecognitionService.shared.start(
                    language: self.preferredLanguage
                )
            }
        }
    }

    // MARK: - Conversation Context

    /// How many recent messages of the current session get sent to an AI
    /// classification call as conversational context.
    private static let conversationContextWindow = 8

    // MARK: - Commands

    func sendCommand(
        _ text: String,
        source: CommandSource
    ) {

        let trimmed =
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty else {
            return
        }

        appendMessage(
            role: .user,
            text: trimmed
        )

        // MARK: Runtime v1 bounded autonomous execution
        //
        // `/auto` continues the most recent running AgentTask until
        // completion, approval, failure, pause, or the per-cycle safety cap.

        if trimmed.lowercased() == "/auto" {

            guard let runtimeTask =
                    taskRuntime.tasks.last(
                        where: { $0.status == .running }
                    )
            else {
                addAssistantMessage(
                    "Δεν υπάρχει ενεργό running autonomous task. Δημιούργησε πρώτα ένα με /plan."
                )
                return
            }

            isProcessing = true
            lastResponseSummary =
                "Autonomous execution — task \(runtimeTask.id.uuidString.prefix(8))…"

            let recentHistory =
                Array(
                    chatMessages
                        .dropLast()
                        .suffix(Self.conversationContextWindow)
                )

            Task {

                defer {
                    isProcessing = false
                }

                do {
                    let report =
                        try await taskExecutor.executeUntilBlocked(
                            taskId: runtimeTask.id,
                            recentHistory: recentHistory,
                            maxStepsPerCycle: 8
                        )

                    guard let updatedTask =
                            taskRuntime.task(id: runtimeTask.id)
                    else {
                        throw RuntimeIntegrationError.taskNotFound
                    }

                    let progressPercent =
                        Int(report.progress * 100)

                    let nextText =
                        report.nextStepTitle ?? "κανένα"

                    let checkpoint =
                        report.lastCheckpoint ?? "κανένα"

                    let failureText =
                        report.failureReason.map {
                            "\nFAILURE\n\($0)"
                        } ?? ""

                    let response = """
                    AUTONOMOUS RUN STOPPED

                    TASK
                    \(updatedTask.id.uuidString)

                    STATUS
                    \(updatedTask.status.rawValue)

                    STOP REASON
                    \(report.stopReason.rawValue)

                    STEPS ATTEMPTED THIS CYCLE
                    \(report.stepsAttempted)

                    PROGRESS
                    \(progressPercent)%

                    LAST CHECKPOINT
                    \(checkpoint)

                    NEXT RUNNABLE STEP
                    \(nextText)
                    \(failureText)
                    """

                    addAssistantMessage(response)

                    lastResponseSummary =
                        "Auto: \(updatedTask.status.rawValue) — \(progressPercent)%"

                } catch {
                    let message =
                        "Autonomous runtime error: \(error.localizedDescription)"

                    addAssistantMessage(message)
                    lastResponseSummary = message
                }
            }

            return
        }

        // MARK: Runtime v1 single-step execution
        //
        // `/run` executes exactly ONE step from the most recent running
        // AgentTask. The step is routed through AgentTaskExecutor, then
        // independently verified against its success criteria.
        //
        // This is intentionally single-step while Runtime v1 is being
        // hardened. A scheduler/worker loop will be added only after this
        // execution path is proven reliable.

        if trimmed.lowercased() == "/run" {

            guard let runtimeTask =
                    taskRuntime.tasks.last(
                        where: { $0.status == .running }
                    )
            else {
                addAssistantMessage(
                    "Δεν υπάρχει ενεργό running autonomous task. Δημιούργησε πρώτα ένα με /plan."
                )
                return
            }

            isProcessing = true
            lastResponseSummary =
                "Εκτέλεση step για task \(runtimeTask.id.uuidString.prefix(8))…"

            let recentHistory =
                Array(
                    chatMessages
                        .dropLast()
                        .suffix(Self.conversationContextWindow)
                )

            Task {

                defer {
                    isProcessing = false
                }

                do {

                    let nextAfterExecution =
                        try await taskExecutor.executeNextStep(
                            taskId: runtimeTask.id,
                            recentHistory: recentHistory
                        )

                    guard let updatedTask =
                            taskRuntime.task(id: runtimeTask.id)
                    else {
                        throw RuntimeIntegrationError.taskNotFound
                    }

                    let progressPercent =
                        Int(
                            taskRuntime.progress(taskId: runtimeTask.id)
                            * 100
                        )

                    let nextText =
                        nextAfterExecution.map {
                            "#\($0.order) — \($0.title)"
                        } ?? "κανένα"

                    let checkpoint =
                        updatedTask.executionState
                            .lastCheckpoint?
                            .summary
                        ?? "κανένα"

                    let response = """
                    RUNTIME STEP RESULT

                    TASK
                    \(updatedTask.id.uuidString)

                    STATUS
                    \(updatedTask.status.rawValue)

                    PROGRESS
                    \(progressPercent)%

                    LAST CHECKPOINT
                    \(checkpoint)

                    NEXT RUNNABLE STEP
                    \(nextText)
                    """

                    addAssistantMessage(response)

                    lastResponseSummary =
                        "Task \(updatedTask.status.rawValue) — \(progressPercent)%"

                } catch {

                    let message =
                        "Runtime execution error: \(error.localizedDescription)"

                    addAssistantMessage(message)

                    lastResponseSummary = message
                }
            }

            return
        }

        // MARK: Runtime v1 planning integration
        //
        // `/plan <goal>` now performs the first complete Runtime v1
        // lifecycle:
        //
        // User Goal
        //    ↓
        // TaskPlanner
        //    ↓
        // validated TaskPlan
        //    ↓
        // AgentTaskRuntime.createTask
        //    ↓
        // AgentTaskRuntime.attachPlan
        //    ↓
        // AgentTaskRuntime.start
        //    ↓
        // nextRunnableStep
        //
        // IMPORTANT:
        //
        // The runnable step is NOT executed here.
        //
        // Actual capability execution belongs to AgentTaskExecutor,
        // which will sit behind policy and approval enforcement.

        if trimmed.lowercased().hasPrefix("/plan ") {

            let goal =
                String(
                    trimmed.dropFirst("/plan ".count)
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            guard !goal.isEmpty else {
                addAssistantMessage(
                    "Χρήση: /plan <στόχος>"
                )
                return
            }

            isProcessing = true
            lastResponseSummary =
                "Δημιουργία autonomous task…"

            Task {

                defer {
                    isProcessing = false
                }

                do {

                    // MARK: 1. Discover available capabilities

                    let capabilityIds =
                        orchestrator.capabilities.map(\.id)

                    // MARK: 2. Generate validated execution plan

                    let plan =
                        try await TaskPlanner.shared.makePlan(
                            for: goal,
                            availableCapabilities: capabilityIds
                        )

                    // MARK: 3. Create runtime task

                    let createdTask =
                        taskRuntime.createTask(
                            goal: goal,
                            priority: .medium
                        )

                    // MARK: 4. Attach trusted plan

                    taskRuntime.attachPlan(
                        taskId: createdTask.id,
                        plan: plan
                    )

                    // MARK: 5. Start lifecycle

                    taskRuntime.start(
                        taskId: createdTask.id
                    )

                    // MARK: 6. Resolve first runnable step

                    let nextStep =
                        taskRuntime.nextRunnableStep(
                            taskId: createdTask.id
                        )

                    // MARK: 7. Read canonical runtime state

                    guard let runtimeTask =
                            taskRuntime.task(
                                id: createdTask.id
                            )
                    else {
                        throw RuntimeIntegrationError.taskNotFound
                    }

                    // MARK: 8. Render plan

                    let renderedSteps =
                        runtimeTask.plan.steps
                            .sorted {
                                $0.order < $1.order
                            }
                            .map { step in

                                let dependencies =
                                    step.dependencyStepIds.isEmpty
                                    ? ""
                                    : " [dependencies: \(step.dependencyStepIds.count)]"

                                let capability =
                                    step.capabilityId.map {
                                        " → \($0)"
                                    } ?? ""

                                let approval =
                                    step.requiresApproval
                                    ? " 🔐"
                                    : ""

                                let background =
                                    step.canRunInBackground
                                    ? " ⚙️"
                                    : ""

                                return """
                                \(step.order). \(step.title)\(capability)\(dependencies)\(approval)\(background)
                                """
                            }
                            .joined(separator: "\n")

                    // MARK: 9. Render next runnable step

                    let nextStepText: String

                    if let nextStep {

                        let approvalText =
                            nextStep.requiresApproval
                            ? "YES"
                            : "NO"

                        let backgroundText =
                            nextStep.canRunInBackground
                            ? "YES"
                            : "NO"

                        nextStepText = """
                        NEXT RUNNABLE STEP
                        #\(nextStep.order) — \(nextStep.title)

                        Risk: \(nextStep.riskLevel.rawValue)
                        Approval required: \(approvalText)
                        Background eligible: \(backgroundText)
                        Capability: \(nextStep.capabilityId ?? "unassigned")
                        """

                    } else {

                        nextStepText = """
                        NEXT RUNNABLE STEP
                        None currently available.
                        """
                    }

                    // MARK: 10. Runtime response

                    let response = """
                    AUTONOMOUS TASK CREATED

                    TASK ID
                    \(runtimeTask.id.uuidString)

                    STATUS
                    \(runtimeTask.status.rawValue)

                    PLAN v\(runtimeTask.plan.version)
                    \(runtimeTask.plan.summary)

                    \(renderedSteps)

                    \(nextStepText)
                    """

                    addAssistantMessage(response)

                    lastResponseSummary =
                        "Task running — \(runtimeTask.plan.steps.count) steps"

                } catch {

                    let message =
                        "Runtime planning error: \(error.localizedDescription)"

                    addAssistantMessage(message)

                    lastResponseSummary = message
                }
            }

            return
        }

        // MARK: Normal Orchestrator Command

        let command = TravisCommand(
            text: trimmed,
            source: source,
            status: .awaitingApproval
        )

        pendingCommands.append(command)

        lastResponseSummary =
            "Εντολή σε αναμονή: \(trimmed)"

        let liveSessionId = currentSessionId

        // dropLast() excludes the message just appended above.
        // It is already passed separately as the command being classified.
        let recentHistory =
            Array(
                chatMessages
                    .dropLast()
                    .suffix(Self.conversationContextWindow)
            )

        Task {
            await orchestrator.route(
                trimmed,
                liveSessionId: liveSessionId,
                recentHistory: recentHistory
            )
        }
    }

    // MARK: - Command Approval

    func approveCommand(at index: Int) {

        guard pendingCommands.indices.contains(index) else {
            return
        }

        pendingCommands[index].status = .approved
        lastResponseSummary = "Command approved"
    }

    func denyCommand(at index: Int) {

        guard pendingCommands.indices.contains(index) else {
            return
        }

        pendingCommands[index].status = .cancelled
        lastResponseSummary = "Command denied"
    }

    // MARK: - Permissions

    func togglePermissionEnabled(
        _ permission: TravisPermission
    ) {

        guard let index =
                permissions.firstIndex(
                    where: {
                        $0.id == permission.id
                    }
                )
        else {
            return
        }

        permissions[index].isEnabled.toggle()
    }

    func updatePermission(
        _ permission: TravisPermission,
        to policy: PermissionPolicy
    ) {

        guard let index =
                permissions.firstIndex(
                    where: {
                        $0.id == permission.id
                    }
                )
        else {
            return
        }

        permissions[index].policy = policy
    }

    // MARK: - Voice

    func toggleListening() {

        isListening.toggle()

        currentDeviceState =
            isListening
            ? .listening
            : .idle

        if isListening {

            SpeechRecognitionService.shared.start(
                language: preferredLanguage
            )

        } else {

            SpeechService.shared.stopSpeaking()
            SpeechRecognitionService.shared.stop()
        }
    }

    func updateDeviceState(
        _ newState: DeviceState
    ) {
        currentDeviceState = newState
    }

    // MARK: - Trading Mandates

    /// Active crypto trading standing mandates.
    ///
    /// Refreshed explicitly rather than computed on read because
    /// this is backed by SwiftData model instances mutated outside
    /// TRAVISAppState's observed state.
    var tradingMandates: [StandingPermission] = []

    func refreshTradingMandates() {

        tradingMandates =
            PersistenceService.shared
                .standingPermissions(
                    withKeyPrefix: "trading_"
                )
                .filter {
                    $0.granted
                }
    }

    func revokeTradingMandate(
        _ mandate: StandingPermission
    ) {

        PersistenceService.shared.setPermission(
            mandate.key,
            granted: false
        )

        refreshTradingMandates()
    }

    // MARK: - Generated Files

    /// Shared save-confirmation point for every capability that can end
    /// in writing generated text to a file.
    ///
    /// Currently used by TextTaskCapability and
    /// SelfImprovementCapability.
    func saveGeneratedText(
        _ text: String,
        filename: String? = nil,
        location: String? = nil,
        capabilityId: String
    ) {

        guard let resolved =
                FileLocationService.shared.resolveSaveDirectory(
                    for: location
                )
        else {

            let message =
                "Δεν ήταν δυνατή η αποθήκευση του αρχείου — δεν δόθηκε πρόσβαση στον φάκελο."

            addAssistantMessage(message)
            lastResponseSummary = message

            return
        }

        defer {
            resolved.stopAccessing()
        }

        let resolvedFilename =
            filename
            ?? "travis-text-\(Int(Date().timeIntervalSince1970)).txt"

        let fileURL =
            resolved.url.appendingPathComponent(
                resolvedFilename
            )

        do {

            try text.write(
                to: fileURL,
                atomically: true,
                encoding: .utf8
            )

            PersistenceService.shared.saveFile(
                filename: resolvedFilename,
                path: fileURL.path,
                capabilityId: capabilityId
            )

            addAssistantMessage(
                "Το κείμενο αποθηκεύτηκε: \(fileURL.path)"
            )

            lastResponseSummary =
                "Αποθηκεύτηκε: \(resolvedFilename)"

        } catch {

            let message =
                "Αποτυχία αποθήκευσης: \(error.localizedDescription)"

            addAssistantMessage(message)

            lastResponseSummary = message
        }
    }
}


// MARK: - Runtime Integration Errors

private enum RuntimeIntegrationError: LocalizedError {

    case taskNotFound

    var errorDescription: String? {

        switch self {

        case .taskNotFound:
            return "Το runtime task δεν βρέθηκε μετά τη δημιουργία του."
        }
    }
}
