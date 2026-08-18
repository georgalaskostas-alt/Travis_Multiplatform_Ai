#if os(macOS)
import SwiftUI

struct TravisPremiumCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var telemetry = TravisSystemTelemetry()
    @State private var spin = false
    @State private var pulse = false
    @State private var showingChat = false

    private let cyan = Color(red: 0.08, green: 0.82, blue: 1.0)
    private let blue = Color(red: 0.12, green: 0.42, blue: 1.0)
    private let navy = Color(red: 0.003, green: 0.018, blue: 0.055)
    private let panel = Color(red: 0.007, green: 0.046, blue: 0.105)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                premiumBackground
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 10) {
                        header
                        HStack(alignment: .top, spacing: 10) {
                            navigationRail
                                .frame(width: 200)
                            VStack(spacing: 10) {
                                HStack(alignment: .top, spacing: 10) {
                                    aiCore
                                        .frame(width: 455, height: 455)
                                    VStack(spacing: 10) {
                                        systemStatus
                                        taskPipeline
                                        currentMission
                                    }
                                    .frame(width: 510)
                                    VStack(spacing: 10) {
                                        alertsPanel
                                        quickStats
                                        voicePanel
                                    }
                                    .frame(width: 250)
                                }

                                HStack(spacing: 10) {
                                    gaugeCard(title: "CPU", value: telemetry.cpuPercent, tint: cyan, icon: "cpu")
                                    gaugeCard(title: "RAM", value: telemetry.memoryPercent, tint: .purple, icon: "memorychip")
                                    gaugeCard(title: "DISK", value: telemetry.diskPercent, tint: .orange, icon: "internaldrive")
                                    missionGauge
                                }

                                HStack(alignment: .top, spacing: 10) {
                                    missionActivity
                                    projectIntel
                                    systemWave
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(minWidth: max(1460, geo.size.width), minHeight: max(900, geo.size.height), alignment: .topLeading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            telemetry.start()
            spin = true
            pulse = true
        }
        .onDisappear { telemetry.stop() }
        .sheet(isPresented: $showingChat) {
            ChatView(appState: appState)
                .frame(minWidth: 820, minHeight: 620)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                HexBadgeShape().fill(cyan.opacity(0.10)).frame(width: 52, height: 48)
                HexBadgeShape().stroke(cyan.opacity(0.85), lineWidth: 1)
                Image(systemName: "triangle.inset.filled")
                    .font(.system(size: 29, weight: .black))
                    .foregroundStyle(cyan)
                    .shadow(color: cyan, radius: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("TRAVIS")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .tracking(3)
                Text("AUTONOMOUS INTELLIGENCE SYSTEM")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(cyan)
            }

            Divider().frame(height: 32).overlay(cyan.opacity(0.3))
            statusPill("CORE ONLINE", color: .green)
            statusPill(appState.isInternetEnabled ? "AI LINK READY" : "AI LINK OFF", color: appState.isInternetEnabled ? .green : .orange)
            statusPill(appState.isBusy ? "MISSION ACTIVE" : "STANDBY", color: appState.isBusy ? .orange : cyan)

            Spacer()

            tinyMetric("CPU", telemetry.cpuPercent)
            tinyMetric("RAM", telemetry.memoryPercent)
            tinyMetric("DSK", telemetry.diskPercent)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Date.now, style: .time)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Text("UPTIME \(telemetry.uptime)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            premiumIconButton("magnifyingglass") { appState.selectedSidebarItem = .history }
            premiumIconButton("gearshape.fill") { appState.selectedSidebarItem = .settings }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(PremiumPanelShape(cut: 18).fill(panel.opacity(0.96)))
        .overlay(PremiumPanelShape(cut: 18).stroke(cyan.opacity(0.72), lineWidth: 0.9))
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(LinearGradient(colors: [.clear, cyan, .clear], startPoint: .leading, endPoint: .trailing)).frame(width: 360, height: 1)
        }
        .shadow(color: cyan.opacity(0.12), radius: 15)
    }

    private var navigationRail: some View {
        VStack(spacing: 10) {
            premiumPanel("NAVIGATION", icon: "dot.scope") {
                railButton("DASHBOARD", "square.grid.2x2.fill") { }
                railButton("CHAT", "message.fill") { showingChat = true }
                railButton("HISTORY", "clock.arrow.circlepath") { appState.selectedSidebarItem = .history }
                railButton("TASKS", "checklist") { appState.selectedSidebarItem = .tasks }
                railButton("PERMISSIONS", "lock.shield.fill") { appState.selectedSidebarItem = .permissions }
                railButton("SETTINGS", "gearshape.fill") { appState.selectedSidebarItem = .settings }
            }

            premiumPanel("QUICK ACTIONS", icon: "bolt.fill") {
                railButton("NEW MISSION", "plus.circle.fill") { showingChat = true; appState.chatInput = "/plan " }
                railButton("NEW PROJECT", "folder.badge.plus") { showingChat = true; appState.chatInput = "Φτιάξε project " }
                railButton("TASK STATUS", "waveform.path.ecg") { showingChat = true; appState.chatInput = "/task-status " }
            }

            premiumPanel("VOICE CONTROL", icon: "waveform") {
                Button { appState.toggleListening() } label: {
                    VStack(spacing: 7) {
                        ZStack {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .stroke(cyan.opacity(0.18 + Double(i) * 0.14), style: StrokeStyle(lineWidth: 1, dash: i == 1 ? [3, 5] : []))
                                    .frame(width: CGFloat(92 - i * 17), height: CGFloat(92 - i * 17))
                                    .rotationEffect(.degrees(spin ? Double((i + 1) * 120) : 0))
                                    .animation(.linear(duration: Double(10 + i * 4)).repeatForever(autoreverses: false), value: spin)
                            }
                            Circle().fill(cyan.opacity(appState.isListening ? 0.18 : 0.06)).frame(width: 50, height: 50)
                            Image(systemName: appState.isListening ? "waveform" : "mic.fill")
                                .font(.system(size: 23, weight: .bold))
                                .foregroundStyle(cyan)
                                .shadow(color: cyan, radius: 10)
                        }
                        Text(appState.isListening ? "LISTENING" : "VOICE STANDBY")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(appState.isListening ? .green : cyan)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            premiumPanel("SECURITY", icon: "shield.lefthalf.filled") {
                dataLine("APPROVALS", "ENABLED", .green)
                dataLine("LOCAL MODE", "ACTIVE", .green)
                dataLine("CLOUD", appState.isInternetEnabled ? "AVAILABLE" : "OFF", appState.isInternetEnabled ? cyan : .orange)
            }
            Spacer(minLength: 0)
        }
    }

    private var aiCore: some View {
        premiumPanel("AI CORE", icon: "atom") {
            ZStack {
                coreGrid

                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .trim(from: i % 2 == 0 ? 0.02 : 0.18, to: i % 2 == 0 ? 0.82 : 0.96)
                        .stroke(
                            i < 3 ? cyan.opacity(0.92) : blue.opacity(0.34),
                            style: StrokeStyle(
                                lineWidth: i == 0 ? 2.2 : 1,
                                lineCap: .round,
                                dash: i % 3 == 0 ? [2, 6] : []
                            )
                        )
                        .frame(width: CGFloat(385 - i * 37), height: CGFloat(385 - i * 37))
                        .rotationEffect(.degrees(spin ? Double((i % 2 == 0 ? 1 : -1) * (100 + i * 24)) : 0))
                        .animation(.linear(duration: Double(17 + i * 3)).repeatForever(autoreverses: false), value: spin)
                }

                ForEach(0..<24, id: \.self) { i in
                    Capsule()
                        .fill(cyan.opacity(i % 4 == 0 ? 0.95 : 0.24))
                        .frame(width: 2, height: i % 4 == 0 ? 16 : 7)
                        .offset(y: -197)
                        .rotationEffect(.degrees(Double(i) * 15))
                }

                Circle()
                    .fill(RadialGradient(colors: [cyan.opacity(0.33), Color(red: 0.00, green: 0.06, blue: 0.13)], center: .center, startRadius: 0, endRadius: 88))
                    .frame(width: 170, height: 170)
                    .overlay(Circle().stroke(cyan, lineWidth: 1.6))
                    .shadow(color: cyan.opacity(pulse ? 0.95 : 0.35), radius: pulse ? 30 : 12)
                    .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: pulse)

                VStack(spacing: 4) {
                    Text("TRAVIS")
                        .font(.system(size: 31, weight: .black, design: .rounded))
                        .tracking(2.2)
                    Text(coreState)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(appState.isBusy ? .orange : .green)
                    HStack(spacing: 3) {
                        ForEach(0..<11, id: \.self) { i in
                            Capsule().fill(cyan.opacity(0.35 + Double(i % 3) * 0.25)).frame(width: 3, height: CGFloat(5 + (i % 5) * 3))
                        }
                    }
                }

                VStack {
                    Spacer()
                    HStack {
                        coreChip("PLANNER", appState.isProcessing)
                        Spacer()
                        coreChip("EXECUTOR", appState.isBusy)
                        Spacer()
                        coreChip("VERIFIER", appState.isBusy)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var systemStatus: some View {
        premiumPanel("SYSTEM OVERVIEW", icon: "server.rack") {
            statusRow("TRAVIS CORE", "OPERATIONAL", "cpu", .green)
            statusRow("LOCAL ENGINE", "ACTIVE", "desktopcomputer", .green)
            statusRow("AI LINK", appState.isInternetEnabled ? "READY" : "OFFLINE", "sparkles", appState.isInternetEnabled ? .green : .orange)
            statusRow("TASK ENGINE", appState.isBusy ? "EXECUTING" : "READY", "gearshape.2.fill", appState.isBusy ? .orange : .green)
            statusRow("VOICE", appState.isListening ? "LISTENING" : "STANDBY", "mic.fill", appState.isListening ? .green : cyan)
        }
    }

    private var taskPipeline: some View {
        premiumPanel("AUTONOMOUS FLOW", icon: "arrow.triangle.branch") {
            HStack(spacing: 2) {
                flowNode("INPUT", "tray.and.arrow.down.fill", true)
                flowConnector
                flowNode("PLAN", "brain.head.profile", appState.isProcessing)
                flowConnector
                flowNode("RUN", "bolt.fill", appState.isBusy)
                flowConnector
                flowNode("CHECK", "checkmark.shield.fill", appState.isBusy)
                flowConnector
                flowNode("DONE", "checkmark.circle.fill", !appState.isBusy, .green)
            }
            .padding(.vertical, 3)
        }
    }

    private var currentMission: some View {
        let task = activeRuntimeTask
        let done = task?.plan.steps.filter { $0.status == .completed }.count ?? 0
        let total = task?.plan.steps.count ?? 0
        let progress = total > 0 ? Double(done) / Double(total) : 0

        return premiumPanel("CURRENT MISSION", icon: "scope") {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(task?.title ?? "Awaiting mission")
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(task?.plan.summary.isEmpty == false ? task!.plan.summary : appState.lastResponseSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack {
                        Text(task?.status.rawValue.uppercased() ?? "READY")
                        Spacer()
                        Text("\(done)/\(total) STEPS")
                    }
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(cyan)
                    ProgressView(value: progress).tint(cyan)
                }
                circularGauge(value: progress * 100, label: "MISSION", tint: cyan)
                    .frame(width: 74, height: 74)
            }
        }
    }

    private var alertsPanel: some View {
        premiumPanel("ALERTS", icon: "bell.badge.fill") {
            alertLine("SYSTEM", "Nominal", .green)
            alertLine("APPROVAL", waitingApprovals > 0 ? "\(waitingApprovals) waiting" : "Clear", waitingApprovals > 0 ? .orange : .green)
            alertLine("FAILED", failedTasks > 0 ? "\(failedTasks) task(s)" : "None", failedTasks > 0 ? .red : .green)
        }
    }

    private var quickStats: some View {
        premiumPanel("MISSION STATS", icon: "chart.bar.fill") {
            dataLine("TOTAL", "\(appState.taskRuntime.tasks.count)", cyan)
            dataLine("RUNNING", "\(runningTasks)", runningTasks > 0 ? .orange : cyan)
            dataLine("DONE", "\(completedTasks)", .green)
            dataLine("FAILED", "\(failedTasks)", failedTasks > 0 ? .red : .secondary)
        }
    }

    private var voicePanel: some View {
        premiumPanel("LIVE STATUS", icon: "waveform.path.ecg") {
            Text(appState.lastResponseSummary)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack {
                Circle().fill(appState.isBusy ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(appState.isBusy ? "TRAVIS IS WORKING" : "TRAVIS IS READY")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(appState.isBusy ? .orange : .green)
            }
        }
    }

    private func gaugeCard(title: String, value: Double, tint: Color, icon: String) -> some View {
        premiumPanel(title, icon: icon) {
            HStack(spacing: 12) {
                circularGauge(value: value, label: "%", tint: tint).frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.0f%%", value)).font(.system(size: 22, weight: .black, design: .rounded))
                    miniEqualizer(value: value, tint: tint)
                    Text("LIVE").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var missionGauge: some View {
        let active = Double(runningTasks)
        return premiumPanel("MISSIONS", icon: "scope") {
            HStack(spacing: 12) {
                circularGauge(value: min(active * 20, 100), label: "ACTIVE", tint: .green).frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(runningTasks)").font(.system(size: 22, weight: .black, design: .rounded))
                    Text("RUNNING NOW").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                    Text("\(completedTasks) completed").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var missionActivity: some View {
        let events = appState.taskRuntime.tasks.flatMap(\.events).sorted { $0.createdAt > $1.createdAt }.prefix(7)
        return premiumPanel("MISSION ACTIVITY", icon: "list.bullet.rectangle") {
            if events.isEmpty {
                Text("No mission activity yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(events), id: \.id) { event in
                    HStack(alignment: .top, spacing: 7) {
                        Circle().fill(event.type == .failed ? Color.red : cyan).frame(width: 5, height: 5).padding(.top, 4)
                        Text(event.type.rawValue.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(event.type == .failed ? .red : cyan).frame(width: 70, alignment: .leading)
                        Text(event.message).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var projectIntel: some View {
        premiumPanel("INTELLIGENCE", icon: "brain") {
            dataLine("TASK MEMORY", "\(appState.taskRuntime.tasks.count)", cyan)
            dataLine("SESSION", String(appState.currentSessionId.uuidString.prefix(8)), .purple)
            dataLine("VOICE", appState.isListening ? "LIVE" : "STANDBY", appState.isListening ? .green : cyan)
            dataLine("MODE", appState.isInternetEnabled ? "HYBRID" : "LOCAL", appState.isInternetEnabled ? cyan : .green)
        }
        .frame(width: 300)
    }

    private var systemWave: some View {
        premiumPanel("SYSTEM SIGNAL", icon: "waveform") {
            TimelineView(.animation(minimumInterval: 0.12)) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    var p = Path()
                    let mid = size.height / 2
                    for x in stride(from: 0.0, through: size.width, by: 3.0) {
                        let n = x / size.width
                        let y = mid + sin(n * 18 + t * 2.4) * 12 + sin(n * 47 + t * 1.3) * 5
                        if x == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(p, with: .color(cyan.opacity(0.95)), lineWidth: 1.4)
                    context.stroke(p, with: .color(cyan.opacity(0.18)), lineWidth: 7)
                }
            }
            .frame(height: 86)
            HStack { Text("CPU \(Int(telemetry.cpuPercent))%"); Spacer(); Text("RAM \(Int(telemetry.memoryPercent))%"); Spacer(); Text("DISK \(Int(telemetry.diskPercent))%") }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 390)
    }

    private var coreGrid: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for radius in stride(from: CGFloat(60), through: 205, by: 29) {
                context.stroke(Path(ellipseIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)), with: .color(cyan.opacity(0.055)), lineWidth: 0.5)
            }
            for angle in stride(from: 0.0, to: 360.0, by: 15.0) {
                let r = angle * .pi / 180
                var p = Path(); p.move(to: center); p.addLine(to: CGPoint(x: center.x + cos(r)*205, y: center.y + sin(r)*205))
                context.stroke(p, with: .color(cyan.opacity(angle.truncatingRemainder(dividingBy: 45) == 0 ? 0.08 : 0.025)), lineWidth: 0.5)
            }
        }
    }

    private var premiumBackground: some View {
        ZStack {
            LinearGradient(colors: [navy, Color(red: 0.002, green: 0.055, blue: 0.13), navy], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let grid: CGFloat = 30
                var p = Path()
                stride(from: CGFloat.zero, through: size.width, by: grid).forEach { x in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                stride(from: CGFloat.zero, through: size.height, by: grid).forEach { y in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(p, with: .color(cyan.opacity(0.032)), lineWidth: 0.45)

                for y in stride(from: CGFloat(80), through: size.height, by: 180) {
                    var circuit = Path(); circuit.move(to: CGPoint(x: 0, y: y)); circuit.addLine(to: CGPoint(x: 140, y: y)); circuit.addLine(to: CGPoint(x: 180, y: y + 35)); circuit.addLine(to: CGPoint(x: 330, y: y + 35))
                    context.stroke(circuit, with: .color(cyan.opacity(0.055)), lineWidth: 0.8)
                }
            }
            RadialGradient(colors: [cyan.opacity(0.07), .clear], center: .center, startRadius: 20, endRadius: 620)
        }
        .ignoresSafeArea()
    }

    private var activeRuntimeTask: AgentTask? {
        appState.taskRuntime.tasks.first { [.running, .planning, .waitingForApproval, .waitingForDependency].contains($0.status) }
            ?? appState.taskRuntime.tasks.first
    }
    private var runningTasks: Int { appState.taskRuntime.tasks.filter { $0.status == .running }.count }
    private var completedTasks: Int { appState.taskRuntime.tasks.filter { $0.status == .completed }.count }
    private var failedTasks: Int { appState.taskRuntime.tasks.filter { $0.status == .failed }.count }
    private var waitingApprovals: Int { appState.taskRuntime.tasks.filter { $0.status == .waitingForApproval }.count }
    private var coreState: String { appState.isProcessing ? "PROCESSING" : appState.isBusy ? "EXECUTING" : "ONLINE" }

    private func premiumPanel<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).tracking(1.1)
                Spacer()
                HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Circle().fill(cyan.opacity(0.55)).frame(width: 3, height: 3) } }
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(cyan)
            content()
        }
        .padding(11)
        .background(PremiumPanelShape(cut: 12).fill(panel.opacity(0.92)))
        .overlay(PremiumPanelShape(cut: 12).stroke(cyan.opacity(0.46), lineWidth: 0.8))
        .overlay(alignment: .topLeading) { Rectangle().fill(cyan.opacity(0.8)).frame(width: 44, height: 1) }
        .shadow(color: cyan.opacity(0.07), radius: 9)
    }

    private func railButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 20).foregroundStyle(cyan)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(cyan.opacity(0.5))
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumHUDButtonStyle(cyan: cyan))
    }

    private func premiumIconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 30, height: 30).foregroundStyle(cyan) }
            .buttonStyle(PremiumHUDButtonStyle(cyan: cyan))
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5).shadow(color: color, radius: 4); Text(text) }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.07)))
            .overlay(Capsule().stroke(color.opacity(0.25)))
    }

    private func tinyMetric(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 2) { Text(label).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.secondary); Text("\(Int(value))%").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(cyan) }
        .frame(width: 42)
    }

    private func statusRow(_ name: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(cyan).frame(width: 18); Text(name).font(.system(size: 8, weight: .bold, design: .monospaced)); Spacer(); Circle().fill(color).frame(width: 5, height: 5).shadow(color: color, radius: 4); Text(value).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(color) }.padding(.vertical, 3)
    }

    private func dataLine(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack { Text(name).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Text(value).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(color) }.padding(.vertical, 2)
    }

    private func alertLine(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack { Circle().fill(color).frame(width: 5, height: 5); Text(name).font(.system(size: 8, weight: .bold, design: .monospaced)); Spacer(); Text(value).font(.system(size: 8, design: .monospaced)).foregroundStyle(color) }.padding(.vertical, 3)
    }

    private func flowNode(_ title: String, _ icon: String, _ active: Bool, _ color: Color? = nil) -> some View {
        let tint = color ?? cyan
        return VStack(spacing: 4) {
            ZStack { Circle().fill(tint.opacity(active ? 0.14 : 0.03)).frame(width: 38, height: 38); Circle().stroke(tint.opacity(active ? 0.75 : 0.12)).frame(width: 38, height: 38); Image(systemName: icon).font(.system(size: 12)).foregroundStyle(active ? tint : .secondary) }
            Text(title).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(active ? .primary : .secondary)
        }.frame(width: 62)
    }

    private var flowConnector: some View { HStack(spacing: 1) { Rectangle().fill(cyan.opacity(0.2)).frame(height: 1); Image(systemName: "chevron.right").font(.system(size: 6)).foregroundStyle(cyan.opacity(0.55)) }.frame(maxWidth: .infinity) }

    private func circularGauge(value: Double, label: String, tint: Color) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.10), lineWidth: 5)
            Circle().trim(from: 0, to: min(max(value / 100, 0), 1)).stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).shadow(color: tint.opacity(0.7), radius: 4)
            Text(label).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(tint)
        }
    }

    private func miniEqualizer(value: Double, tint: Color) -> some View {
        HStack(spacing: 2) { ForEach(0..<12, id: \.self) { i in Capsule().fill(Double(i) < value / 8.4 ? tint : tint.opacity(0.10)).frame(width: 3, height: CGFloat(5 + (i % 5) * 2)) } }
    }

    private func coreChip(_ text: String, _ active: Bool) -> some View {
        Text(text).font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(active ? .green : cyan.opacity(0.7)).padding(.horizontal, 7).padding(.vertical, 4).background(Capsule().fill(cyan.opacity(0.05))).overlay(Capsule().stroke(cyan.opacity(0.20)))
    }
}

private struct PremiumPanelShape: Shape {
    let cut: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: cut, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX - 8, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 8))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        p.addLine(to: CGPoint(x: 8, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY - 8))
        p.addLine(to: CGPoint(x: 0, y: cut))
        p.closeSubpath()
        return p
    }
}

private struct HexBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.22, y: 0))
        p.addLine(to: CGPoint(x: rect.width * 0.78, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.5))
        p.addLine(to: CGPoint(x: rect.width * 0.78, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width * 0.22, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: rect.height * 0.5))
        p.closeSubpath()
        return p
    }
}

private struct PremiumHUDButtonStyle: ButtonStyle {
    let cyan: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .background(PremiumPanelShape(cut: 5).fill(cyan.opacity(configuration.isPressed ? 0.18 : 0.035)))
            .overlay(PremiumPanelShape(cut: 5).stroke(cyan.opacity(configuration.isPressed ? 0.65 : 0.12), lineWidth: 0.7))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
