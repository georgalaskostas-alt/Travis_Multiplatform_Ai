#if os(iOS)

import SwiftUI

struct iOSPremiumChatWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @FocusState private var inputFocused: Bool

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    var body: some View {
        ZStack {
            premiumBackground

            VStack(spacing: 0) {
                workspaceHeader(title: "TRAVIS CHAT", subtitle: appState.isBusy ? "PROCESSING" : "SECURE COMMAND CHANNEL", icon: "message.fill")

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if appState.chatMessages.isEmpty {
                                emptyState
                            }

                            ForEach(appState.chatMessages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                    .onChange(of: appState.chatMessages.count) { _, _ in
                        guard let last = appState.chatMessages.last else { return }
                        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                composer
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(cyan.opacity(0.08)).frame(width: 94, height: 94)
                Circle().stroke(cyan.opacity(0.48), lineWidth: 1).frame(width: 94, height: 94)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(cyan)
                    .shadow(color: cyan.opacity(0.7), radius: 8)
            }
            Text("TRAVIS READY")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(1.2)
            Text("Type or speak a command. The same TRAVIS runtime and mission engine remain active behind this interface.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 34) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        Circle().fill(cyan).frame(width: 5, height: 5).shadow(color: cyan, radius: 4)
                    }
                    Text(message.role == .user ? "YOU" : "TRAVIS")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(message.role == .user ? .white.opacity(0.62) : cyan)
                }

                Text(message.text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.role == .user ? Color.white.opacity(0.08) : panel.opacity(0.94))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(message.role == .user ? Color.white.opacity(0.14) : cyan.opacity(0.42), lineWidth: 0.8)
                    )
            }

            if message.role == .assistant { Spacer(minLength: 34) }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Button {
                    appState.toggleListening()
                } label: {
                    Image(systemName: appState.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(appState.isListening ? .green : cyan)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.34)))
                        .overlay(Circle().stroke((appState.isListening ? Color.green : cyan).opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)

                TextField("Command TRAVIS…", text: $appState.chatInput, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.black.opacity(0.34)))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(cyan.opacity(inputFocused ? 0.55 : 0.24), lineWidth: 1))
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(cyan))
                        .shadow(color: cyan.opacity(0.45), radius: 8)
                }
                .buttonStyle(.plain)
                .disabled(appState.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(appState.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }

            HStack {
                Label(appState.isInternetEnabled ? "AI ROUTING ONLINE" : "LOCAL MODE", systemImage: "shield.checkered")
                Spacer()
                Text(appState.isBusy ? "EXECUTING" : "READY")
                    .foregroundStyle(appState.isBusy ? .orange : .green)
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            LinearGradient(colors: [.clear, cyan.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }

    private func send() {
        appState.sendChat()
        inputFocused = true
    }

    private var premiumBackground: some View {
        ZStack {
            navy.ignoresSafeArea()
            LinearGradient(colors: [Color.black, navy, panel.opacity(0.88), navy], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            RadialGradient(colors: [cyan.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 390).ignoresSafeArea()
        }
    }

    private func workspaceHeader(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(cyan.opacity(0.09)).frame(width: 42, height: 42)
                RoundedRectangle(cornerRadius: 11).stroke(cyan.opacity(0.55), lineWidth: 1).frame(width: 42, height: 42)
                Image(systemName: icon).foregroundStyle(cyan).font(.system(size: 17, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .heavy, design: .rounded)).tracking(1)
                Text(subtitle).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(cyan.opacity(0.86)).tracking(0.7)
            }
            Spacer()
            Circle().fill(appState.isBusy ? Color.orange : Color.green).frame(width: 7, height: 7)
                .shadow(color: appState.isBusy ? .orange : .green, radius: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(cyan.opacity(0.18)).frame(height: 1) }
    }
}

struct iOSPremiumMissionWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @State private var missionText = ""
    @State private var bridge = TravisDeviceBridgeService.shared
    @FocusState private var focused: Bool

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, navy, panel.opacity(0.92), navy], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    hero
                    missionComposer
                    executionArchitecture
                    runtimeState
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(cyan.opacity(0.18), lineWidth: 1).frame(width: 118, height: 118)
                Circle().stroke(cyan.opacity(0.45), style: StrokeStyle(lineWidth: 4, dash: [18, 9])).frame(width: 100, height: 100)
                Circle().fill(cyan.opacity(0.09)).frame(width: 76, height: 76)
                Image(systemName: "scope").font(.system(size: 32, weight: .medium)).foregroundStyle(cyan).shadow(color: cyan, radius: 8)
            }
            Text("NEW MISSION")
                .font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(1.4)
            Text("Define the objective. TRAVIS will plan, execute, verify and retain the result through the same autonomous runtime used on your Mac.")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private var missionComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("MISSION OBJECTIVE", systemImage: "target")
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(cyan)

            TextField("Describe exactly what you want TRAVIS to achieve…", text: $missionText, axis: .vertical)
                .lineLimit(5...10)
                .focused($focused)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.black.opacity(0.32)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(cyan.opacity(focused ? 0.58 : 0.24), lineWidth: 1))

            Button(action: launchMission) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("LAUNCH MISSION")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12).fill(cyan))
                .shadow(color: cyan.opacity(0.35), radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(missionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(missionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
        .padding(14)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private var executionArchitecture: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AUTONOMOUS PIPELINE", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(cyan)
            HStack(spacing: 6) {
                pipelineTile("PLAN", "scope")
                pipelineTile("EXEC", "bolt.fill")
                pipelineTile("VERIFY", "checkmark.shield.fill")
                pipelineTile("MEM", "memorychip.fill")
            }
        }
        .padding(14)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private var runtimeState: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MAC RUNTIME").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text(bridge.isConnected ? "CONNECTED" : "LOCAL FALLBACK")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(bridge.isConnected ? .green : .orange)
            }
            Spacer()
            if let status = bridge.lastStatus {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ACTIVE TASKS").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    Text("\(status.activeRuntimeTasks)").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(cyan)
                }
            }
        }
        .padding(14)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private func pipelineTile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(cyan).font(.system(size: 15, weight: .bold))
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(cyan.opacity(0.24), lineWidth: 0.8))
    }

    private func launchMission() {
        let goal = missionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        let command = "/plan \(goal)"
        if bridge.isConnected {
            bridge.sendCommandToMac(command)
            appState.appendMessage(role: .user, text: command)
            appState.addAssistantMessage("Mission sent to the connected Mac TRAVIS runtime.")
        } else {
            appState.chatInput = command
            appState.sendChat()
        }
        missionText = ""
    }
}

struct iOSPremiumTasksWorkspace: View {
    @Bindable var appState: TRAVISAppState
    @State private var bridge = TravisDeviceBridgeService.shared

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    private var runtimeTasks: [AgentTask] {
        appState.taskRuntime.tasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, navy, panel.opacity(0.92), navy], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 13) {
                    taskHeader
                    summaryGrid

                    if runtimeTasks.isEmpty {
                        emptyTasks
                    } else {
                        ForEach(runtimeTasks) { task in taskCard(task) }
                    }

                    macRuntimeCard
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if bridge.isConnected { bridge.requestStatus() }
        }
    }

    private var taskHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(cyan.opacity(0.09)).frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.48), lineWidth: 1).frame(width: 48, height: 48)
                Image(systemName: "checklist").font(.system(size: 20, weight: .bold)).foregroundStyle(cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("TASK CONTROL").font(.system(size: 19, weight: .heavy, design: .rounded)).tracking(1)
                Text("AUTONOMOUS RUNTIME QUEUE").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(cyan)
            }
            Spacer()
            Circle().fill(bridge.isConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                .shadow(color: bridge.isConnected ? .green : .orange, radius: 5)
        }
        .padding(14)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private var summaryGrid: some View {
        let running = runtimeTasks.filter { [.running, .planning].contains($0.status) }.count
        let waiting = runtimeTasks.filter { [.waitingForApproval, .waitingForDependency, .paused, .pending].contains($0.status) }.count
        let completed = runtimeTasks.filter { $0.status == .completed }.count
        let failed = runtimeTasks.filter { $0.status == .failed }.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            summaryTile("RUNNING", "\(running)", .green)
            summaryTile("WAITING", "\(waiting)", .orange)
            summaryTile("COMPLETED", "\(completed)", cyan)
            summaryTile("FAILED", "\(failed)", .red)
        }
    }

    private var emptyTasks: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(cyan)
            Text("NO LOCAL TASKS").font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("The connected Mac runtime can still have active missions. Its live count is shown below.")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private func taskCard(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(task.goal).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 8)
                statusBadge(task.status)
            }

            if !task.plan.steps.isEmpty {
                let completed = task.plan.steps.filter { $0.status == .completed }.count
                ProgressView(value: Double(completed), total: Double(max(task.plan.steps.count, 1)))
                    .tint(cyan)
                HStack {
                    Text("\(completed)/\(task.plan.steps.count) STEPS")
                    Spacer()
                    Text(task.priority.rawValue.uppercased())
                }
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private var macRuntimeCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("MAC TRAVIS", systemImage: "desktopcomputer")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(cyan)
                Spacer()
                Text(bridge.isConnected ? "CONNECTED" : "OFFLINE")
                    .font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(bridge.isConnected ? .green : .orange)
            }
            if let status = bridge.lastStatus {
                HStack {
                    Text("ACTIVE RUNTIME TASKS")
                    Spacer()
                    Text("\(status.activeRuntimeTasks)").foregroundStyle(cyan)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                if !status.lastSummary.isEmpty {
                    Text(status.lastSummary).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Text("Waiting for runtime status…").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .mobileHUD(cyan: cyan, panel: panel)
    }

    private func summaryTile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.24), lineWidth: 0.8))
    }

    private func statusBadge(_ status: AgentTaskStatus) -> some View {
        let color: Color = switch status {
        case .completed: .green
        case .failed, .cancelled: .red
        case .running, .planning: cyan
        case .waitingForApproval, .waitingForDependency, .paused: .orange
        case .pending: .secondary
        }

        return Text(status.rawValue.replacingOccurrences(of: "waitingFor", with: "WAIT ").uppercased())
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.7))
    }
}

private extension View {
    func mobileHUD(cyan: Color, panel: Color) -> some View {
        background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [.white.opacity(0.05), panel.opacity(0.96), Color.black.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(LinearGradient(colors: [.white.opacity(0.16), cyan.opacity(0.48), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 12, y: 7)
        .shadow(color: cyan.opacity(0.06), radius: 8)
    }
}

#endif
