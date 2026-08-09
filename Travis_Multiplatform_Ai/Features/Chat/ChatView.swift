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

    /// A single chronological chat entry — either a message bubble or an
    /// approval card, merged by `createdAt` so proposed actions render
    /// inline in the flow at the point they arose, not in a separate
    /// section. Approval behavior itself (`proposalCard`) is unchanged
    /// from before this merge.
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

    private var timelineItems: [TimelineItem] {
        let messageItems = appState.chatMessages.map(TimelineItem.message)
        let proposalItems = appState.approvalGate.pendingActions.map(TimelineItem.proposal)
        return (messageItems + proposalItems).sorted { $0.createdAt < $1.createdAt }
    }

    /// Best-effort match against `pendingCommands` (same trimmed text,
    /// still `.awaitingApproval`) — the only correlation available since
    /// `TravisCommand` isn't linked to a `ChatMessage` id. Kept only
    /// because the underlying status still exists; the real approval
    /// mechanism is the `ProposedAction` cards, unaffected by this.
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
                        .stroke(Color.cyan.opacity(0.8), lineWidth: 2)
                        .frame(width: 220, height: 220)

                    Circle()
                        .stroke(Color.blue.opacity(0.45), lineWidth: 12)
                        .frame(width: 170, height: 170)

                    VStack(spacing: 8) {
                        Text(appState.assistantName.uppercased())
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(appState.currentDeviceState.title)
                            .font(.caption)
                            .foregroundStyle(.cyan.opacity(0.9))
                    }
                }

                Text(appState.lastResponseSummary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
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

                Button {
                    appState.sendCommand(draft, source: .manual)
                    draft = ""
                } label: {
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

    /// The single chronological chat — messages and approval cards
    /// merged by time, taking up the majority of the available vertical
    /// space. Replaces the old separate "Μηνύματα" and "Command Queue"
    /// sections.
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
                                timelineRow(item)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: timelineItems.count) { _, _ in
                        guard let lastId = timelineItems.last?.id else { return }
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
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
        case .message(let message):
            messageBubble(message)
        case .proposal(let action):
            proposalCard(action)
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

    /// Unchanged from before the merge — same fields, same Approve/Reject
    /// behavior — just rendered inline in the timeline instead of in a
    /// separate "Προτεινόμενες Ενέργειες" section.
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

                Button("Reject") {
                    appState.approvalGate.reject(action)
                }
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

    /// Compact, glanceable preview of the most recent past sessions — the
    /// full browsable list lives in the "Ιστορικό" tab (`ChatHistoryView`).
    /// Reuses `appState.pastSessions`/`viewSession(_:)`, no new loading
    /// logic.
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
                            Button {
                                appState.viewSession(session.id)
                            } label: {
                                recentSessionCard(session)
                            }
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
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.cyan.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.cyan.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.cyan.opacity(0.3), radius: 8, x: 0, y: 0)
    }
}
