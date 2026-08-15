import SwiftUI

struct ChatView: View {
    @Bindable var appState: TRAVISAppState
    @State private var draft: String = ""

    private var isViewingPastSession: Bool {
        appState.viewedSessionId != appState.currentSessionId
    }

    private var sessionHeaderDate: String {
        let date = appState.chatMessages.first?.createdAt ?? Date()
        return Self.sessionDateFormatter.string(from: date)
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()

    private static let recentCardDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()

    private enum TimelineItem: Identifiable {
        case message(ChatMessage)
        case proposal(ProposedAction)

        var id: String {
            switch self {
            case .message(let message): return "message-\(message.id)"
            case .proposal(let action): return "proposal-\(action.id)"
            }
        }

        var createdAt: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .proposal(let action): return action.createdAt
            }
        }
    }

    private enum OrbState: Equatable {
        case idle, listening, speaking

        var statusText: String {
            switch self {
            case .idle: return ""
            case .listening: return "Ακούει..."
            case .speaking: return "Μιλάει..."
            }
        }

        var ringColor: Color {
            switch self {
            case .idle, .speaking: return .cyan
            case .listening: return .green
            }
        }

        var scale: CGFloat {
            switch self {
            case .idle: return 1.0
            case .listening: return 1.04
            case .speaking: return 1.08
            }
        }

        var animation: Animation {
            switch self {
            case .idle: return .easeInOut(duration: 0.3)
            case .listening: return .easeInOut(duration: 0.3).repeatForever(autoreverses: true)
            case .speaking: return .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
            }
        }
    }

    private var orbState: OrbState {
        if SpeechService.shared.isSpeaking { return .speaking }
        if SpeechRecognitionService.shared.isListening { return .listening }
        return .idle
    }

    private var timelineItems: [TimelineItem] {
        let messageItems = appState.chatMessages
            .filter { !(appState.isListening && $0.role == .assistant) }
            .map(TimelineItem.message)
        let proposalItems = appState.approvalGate.pendingActions.map(TimelineItem.proposal)
        return (messageItems + proposalItems).sorted { $0.createdAt < $1.createdAt }
    }

    private func isAwaitingApproval(_ message: ChatMessage) -> Bool {
        guard message.role == .user else { return false }
        return appState.pendingCommands.contains { $0.text == message.text && $0.status == .awaitingApproval }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(sessionHeaderDate)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))

                if isViewingPastSession {
                    Text("Παλαιότερη συνομιλία")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.25))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                }

                Spacer()

                if isViewingPastSession {
                    Button("Επιστροφή στην τρέχουσα") {
                        appState.returnToCurrentSession()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.cyan.opacity(0.95),
                                    Color.blue.opacity(0.65),
                                    Color.blue.opacity(0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 140
                            )
                        )
                        .frame(width: 180, height: 180)
                        .blur(radius: 2)

                    Circle()
                        .stroke(orbState.ringColor.opacity(0.8), lineWidth: 2)
                        .frame(width: 220, height: 220)

                    Circle()
                        .stroke(Color.blue.opacity(0.45), lineWidth: 12)
                        .frame(width: 170, height: 170)

                    VStack(spacing: 8) {
                        Text(appState.assistantName.uppercased())
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(orbState == .idle ? appState.currentDeviceState.title : orbState.statusText)
                            .font(.caption)
                            .foregroundStyle(.cyan.opacity(0.9))
                    }
                }
                .scaleEffect(orbState.scale)
                .animation(orbState.animation, value: orbState)

                if orbState == .listening {
                    Text(SpeechRecognitionService.shared.liveTranscript.isEmpty
                         ? "..."
                         : SpeechRecognitionService.shared.liveTranscript)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text(appState.lastResponseSummary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.top)

            recentSessionsPanel
            unifiedChatSection

            HStack(spacing: 12) {
                TextField("Δώσε εντολή στον Travis...", text: $draft)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .submitLabel(.send)
                    .onSubmit { submitDraft() }

                Button { submitDraft() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                Button(appState.isListening ? "Stop Listening" : "Start Listening") {
                    appState.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("Demo Internet Query") {
                    appState.sendCommand("Βρες πληροφορίες από το internet", source: .voice)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.black, Color.blue.opacity(0.45), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Chat Input

    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch trimmed.lowercased() {
        case "/resume":
            resumeRecoveredTask()
            draft = ""
            return
        case "/approve":
            approveWaitingRuntimeStep()
            draft = ""
            return
        case "/reject":
            rejectWaitingRuntimeStep()
            draft = ""
            return
        default:
            break
        }

        appState.sendCommand(trimmed, source: .manual)
        draft = ""
    }

    private func resumeRecoveredTask() {
        guard let recoveredTask = appState.taskRuntime.tasks.last(where: { $0.status == .paused }) else {
            appState.addAssistantMessage("Δεν υπάρχει paused autonomous task για συνέχιση.")
            appState.lastResponseSummary = "No paused autonomous task"
            return
        }

        let checkpoint = recoveredTask.executionState.lastCheckpoint?.summary ?? "κανένα"
        let progressPercent = Int(appState.taskRuntime.progress(taskId: recoveredTask.id) * 100)

        appState.taskRuntime.resume(taskId: recoveredTask.id)

        guard let resumedTask = appState.taskRuntime.task(id: recoveredTask.id) else {
            appState.addAssistantMessage("Το recovered runtime task δεν βρέθηκε μετά το resume.")
            appState.lastResponseSummary = "Runtime resume failed"
            return
        }

        let nextStep = appState.taskRuntime.nextRunnableStep(taskId: resumedTask.id)
        let nextText = nextStep.map { "#\($0.order) — \($0.title)" } ?? "κανένα"

        let response = """
        AUTONOMOUS TASK RECOVERED

        TASK
        \(resumedTask.id.uuidString)

        STATUS
        \(resumedTask.status.rawValue)

        RECOVERY
        Recovered from durable snapshot after application/process restart.
        Continuation required explicit /resume.

        PROGRESS
        \(progressPercent)%

        LAST VERIFIED CHECKPOINT
        \(checkpoint)

        NEXT RUNNABLE STEP
        \(nextText)

        Το task είναι ξανά διαθέσιμο για /run ή /auto.
        """

        appState.addAssistantMessage(response)
        appState.lastResponseSummary = "Recovered task resumed — \(progressPercent)%"
    }

    private func approveWaitingRuntimeStep() {
        guard let task = appState.taskRuntime.tasks.last(where: { $0.status == .waitingForApproval }),
              let stepId = task.executionState.currentStepId,
              let step = task.plan.steps.first(where: { $0.id == stepId && $0.status == .waitingForApproval })
        else {
            appState.addAssistantMessage("Δεν υπάρχει autonomous step που περιμένει έγκριση.")
            appState.lastResponseSummary = "No runtime approval pending"
            return
        }

        appState.taskRuntime.markStepApprovalGranted(taskId: task.id, stepId: step.id)

        guard let updated = appState.taskRuntime.task(id: task.id) else {
            appState.addAssistantMessage("Η έγκριση δεν μπόρεσε να συνδεθεί με το runtime task.")
            appState.lastResponseSummary = "Runtime approval failed"
            return
        }

        let next = appState.taskRuntime.nextRunnableStep(taskId: updated.id)
        let nextText = next.map { "#\($0.order) — \($0.title)" } ?? "κανένα"

        appState.addAssistantMessage("""
        RUNTIME APPROVAL GRANTED

        TASK
        \(updated.id.uuidString)

        STEP
        #\(step.order) — \(step.title)

        STATUS
        \(updated.status.rawValue)

        NEXT RUNNABLE STEP
        \(nextText)

        Η έγκριση εφαρμόστηκε deterministic στο συγκεκριμένο task/step. Μπορείς να συνεχίσεις με /run ή /auto.
        """)
        appState.lastResponseSummary = "Runtime step approved"
    }

    private func rejectWaitingRuntimeStep() {
        guard let task = appState.taskRuntime.tasks.last(where: { $0.status == .waitingForApproval }),
              let stepId = task.executionState.currentStepId,
              let step = task.plan.steps.first(where: { $0.id == stepId && $0.status == .waitingForApproval })
        else {
            appState.addAssistantMessage("Δεν υπάρχει autonomous step που περιμένει απόρριψη.")
            appState.lastResponseSummary = "No runtime approval pending"
            return
        }

        appState.taskRuntime.markStepApprovalRejected(
            taskId: task.id,
            stepId: step.id,
            reason: "Rejected explicitly with /reject"
        )

        appState.addAssistantMessage("""
        RUNTIME APPROVAL REJECTED

        TASK
        \(task.id.uuidString)

        STEP
        #\(step.order) — \(step.title)

        Το task τέθηκε σε paused state και το step δεν θα εκτελεστεί.
        """)
        appState.lastResponseSummary = "Runtime step rejected"
    }

    private var unifiedChatSection: some View {
        Group {
            if timelineItems.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    Text("Ξεκίνα τη συνομιλία...")
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(timelineItems) { item in
                                timelineRow(item).id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: timelineItems.count) { _, _ in
                        guard let lastId = timelineItems.last?.id else { return }
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                    .onAppear {
                        guard let lastId = timelineItems.last?.id else { return }
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem) -> some View {
        switch item {
        case .message(let message): messageBubble(message)
        case .proposal(let action): proposalCard(action)
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .assistant {
                bubbleContent(message)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubbleContent(message)
            }
        }
    }

    private func bubbleContent(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 4) {
            Text(message.text)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(10)
                .background(message.role == .assistant ? Color.white.opacity(0.08) : Color.blue.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 6) {
                if isAwaitingApproval(message) {
                    Text("σε αναμονή")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.3))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                }

                Text(Self.timeFormatter.string(from: message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func proposalCard(_ action: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.summary)
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            Text(action.reasoning)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))

            Text(action.expectedImpact)
                .font(.caption)
                .foregroundStyle(.cyan.opacity(0.85))

            HStack {
                Text("Ρίσκο: \(action.riskLevel.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Reject") { appState.approvalGate.reject(action) }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button("Approve") {
                    appState.approvalGate.approve(action)
                    if let text = action.payload {
                        appState.saveGeneratedText(text, filename: action.filename, location: action.location, capabilityId: action.capabilityId)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding()
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var recentSessionsPanel: some View {
        let recent = Array(appState.pastSessions.prefix(5))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Πρόσφατες συνομιλίες")
                    .font(.headline)
                    .foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recent) { session in
                            Button { appState.viewSession(session.id) } label: { recentSessionCard(session) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func recentSessionCard(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.recentCardDateFormatter.string(from: session.startedAt))
                .font(.caption2.bold())
                .foregroundStyle(.cyan)
            Text(session.preview.isEmpty ? "…" : session.preview)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text("\(session.messages.count) μηνύματα")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(12)
        .frame(width: 150, height: 100, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.3), Color.cyan.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.45), lineWidth: 1))
        .shadow(color: Color.cyan.opacity(0.3), radius: 8)
    }
}