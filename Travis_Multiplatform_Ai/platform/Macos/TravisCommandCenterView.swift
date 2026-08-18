#if os(macOS)
import SwiftUI

struct TravisCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var pulse = false

    private let cyan = Color(red: 0.05, green: 0.72, blue: 1.0)
    private let deep = Color(red: 0.01, green: 0.035, blue: 0.09)

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 12) {
                    topBar
                    HStack(alignment: .top, spacing: 12) {
                        sidebar
                            .frame(width: 180)
                        VStack(spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                corePanel
                                    .frame(minWidth: 430, minHeight: 430)
                                VStack(spacing: 12) {
                                    systemOverview
                                    taskFlow
                                    currentTask
                                }
                                .frame(minWidth: 500)
                            }
                            HStack(alignment: .top, spacing: 12) {
                                metricPanel("CPU", value: "LOCAL", subtitle: "System telemetry next", icon: "cpu")
                                metricPanel("MEMORY", value: "ACTIVE", subtitle: "Project + task memory", icon: "memorychip")
                                metricPanel("TASKS", value: "\(appState.activeTasks.count)", subtitle: "Tracked tasks", icon: "checklist")
                                metricPanel("STATE", value: appState.isBusy ? "BUSY" : "READY", subtitle: appState.lastResponseSummary, icon: "waveform.path.ecg")
                            }
                            HStack(alignment: .top, spacing: 12) {
                                systemLog
                                shortcuts
                                    .frame(width: 300)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(minWidth: max(1180, geo.size.width), alignment: .topLeading)
            }
            .background(commandBackground.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .onAppear { pulse = true }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "triangle.inset.filled")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(cyan)
                .shadow(color: cyan.opacity(0.8), radius: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text("TRAVIS").font(.system(size: 25, weight: .bold, design: .rounded))
                Text("AI ASSISTANT · COMMAND CENTER").font(.caption2).foregroundStyle(cyan)
            }
            Divider().frame(height: 34).overlay(cyan.opacity(0.35))
            Label("SYSTEM OPERATIONAL", systemImage: "circle.fill")
                .font(.caption.bold()).foregroundStyle(.green)
            Spacer()
            Text(Date.now, style: .time).font(.system(.headline, design: .monospaced))
            HUDIconButton(icon: "magnifyingglass") { appState.selectedSidebarItem = .history }
            HUDIconButton(icon: "gearshape") { appState.selectedSidebarItem = .settings }
            HUDIconButton(icon: appState.isListening ? "mic.fill" : "mic") { appState.toggleListening() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            HUDPanel(title: "NAVIGATION") {
                navButton("Dashboard", icon: "square.grid.2x2.fill", target: .chat)
                navButton("Chat", icon: "message.fill", target: .chat)
                navButton("History", icon: "clock.arrow.circlepath", target: .history)
                navButton("Tasks", icon: "checklist", target: .tasks)
                navButton("Permissions", icon: "lock.shield", target: .permissions)
                navButton("Settings", icon: "gearshape", target: .settings)
            }
            HUDPanel(title: "QUICK ACTIONS") {
                actionButton("New Task", icon: "plus.circle") { appState.selectedSidebarItem = .chat; appState.chatInput = "/plan " }
                actionButton("New Project", icon: "folder.badge.plus") { appState.selectedSidebarItem = .chat; appState.chatInput = "Φτιάξε project " }
                actionButton("Task Status", icon: "waveform.path.ecg") { appState.selectedSidebarItem = .chat; appState.chatInput = "/task-status " }
            }
            HUDPanel(title: "VOICE INPUT") {
                Button { appState.toggleListening() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: appState.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 48)).foregroundStyle(cyan)
                            .shadow(color: cyan, radius: appState.isListening ? 16 : 5)
                        Text(appState.isListening ? "LISTENING" : "TAP TO SPEAK")
                            .font(.caption.bold()).foregroundStyle(appState.isListening ? .green : .secondary)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var corePanel: some View {
        HUDPanel(title: "AI CORE") {
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .stroke(index.isMultiple(of: 2) ? cyan.opacity(0.85) : cyan.opacity(0.25), style: StrokeStyle(lineWidth: index == 0 ? 3 : 1, dash: index.isMultiple(of: 2) ? [] : [5, 8]))
                        .frame(width: CGFloat(330 - index * 45), height: CGFloat(330 - index * 45))
                        .rotationEffect(.degrees(pulse ? Double(index * 22 + 40) : Double(index * -18)))
                        .animation(.linear(duration: Double(10 + index * 4)).repeatForever(autoreverses: false), value: pulse)
                }
                Circle().fill(deep).frame(width: 160, height: 160)
                    .overlay(Circle().stroke(cyan, lineWidth: 2))
                    .shadow(color: cyan.opacity(0.8), radius: 25)
                VStack(spacing: 6) {
                    Text("TRAVIS").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(appState.isProcessing ? "PROCESSING" : "ONLINE")
                        .font(.headline.bold()).foregroundStyle(appState.isProcessing ? .orange : .green)
                    Image(systemName: "waveform").foregroundStyle(cyan)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 365)
        }
    }

    private var systemOverview: some View {
        HUDPanel(title: "SYSTEM OVERVIEW") {
            statusRow("TRAVIS Core", value: "Operational", icon: "cpu", good: true)
            statusRow("AI Engine", value: appState.isInternetEnabled ? "Ready" : "Offline", icon: "sparkles", good: appState.isInternetEnabled)
            statusRow("Local Engine", value: "Active", icon: "desktopcomputer", good: true)
            statusRow("Task Runtime", value: appState.isBusy ? "Executing" : "Ready", icon: "gearshape.2", good: true)
            statusRow("Voice", value: appState.isListening ? "Listening" : "Standby", icon: "mic", good: true)
        }
    }

    private var taskFlow: some View {
        HUDPanel(title: "TASK FLOW") {
            HStack(spacing: 4) {
                flowNode("RECEIVED", icon: "tray.and.arrow.down.fill", active: true)
                flowLine
                flowNode("PLANNING", icon: "point.3.connected.trianglepath.dotted", active: appState.isProcessing)
                flowLine
                flowNode("EXECUTING", icon: "play.circle.fill", active: appState.isBusy)
                flowLine
                flowNode("VERIFYING", icon: "checkmark.shield.fill", active: appState.isBusy)
                flowLine
                flowNode("READY", icon: "checkmark.circle.fill", active: !appState.isBusy, green: true)
            }
        }
    }

    private var currentTask: some View {
        HUDPanel(title: "CURRENT TASK") {
            let task = appState.activeTasks.first
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task?.title ?? "No active task").font(.headline)
                    Text(task?.details ?? appState.lastResponseSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(appState.isBusy ? "STATUS: RUNNING" : "STATUS: READY").font(.caption.bold()).foregroundStyle(appState.isBusy ? .orange : .green)
                }
                Spacer()
                ZStack {
                    Circle().stroke(cyan.opacity(0.2), lineWidth: 7)
                    Circle().trim(from: 0, to: appState.isBusy ? 0.68 : 1).stroke(cyan, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text(appState.isBusy ? "68%" : "100%").font(.headline.bold())
                }.frame(width: 72, height: 72)
            }
        }
    }

    private func metricPanel(_ title: String, value: String, subtitle: String, icon: String) -> some View {
        HUDPanel(title: title) {
            HStack { Image(systemName: icon).font(.title2).foregroundStyle(cyan); Text(value).font(.title2.bold()); Spacer() }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProgressView(value: title == "TASKS" ? min(Double(appState.activeTasks.count) / 10, 1) : 0.62).tint(cyan)
        }
        .frame(maxWidth: .infinity)
    }

    private var systemLog: some View {
        HUDPanel(title: "SYSTEM LOG") {
            VStack(alignment: .leading, spacing: 7) {
                logRow("[STATUS]", appState.lastResponseSummary, .green)
                logRow("[TASKS]", "\(appState.activeTasks.count) tasks tracked", cyan)
                logRow("[SESSION]", String(appState.currentSessionId.uuidString.prefix(8)), .secondary)
                logRow("[VOICE]", appState.isListening ? "Listening" : "Standby", appState.isListening ? .green : .secondary)
            }
        }.frame(maxWidth: .infinity)
    }

    private var shortcuts: some View {
        HUDPanel(title: "SHORTCUTS") {
            actionButton("Open Chat", icon: "message") { appState.selectedSidebarItem = .chat }
            actionButton("Show Tasks", icon: "checklist") { appState.selectedSidebarItem = .tasks }
            actionButton("Permissions", icon: "lock.shield") { appState.selectedSidebarItem = .permissions }
            actionButton("Settings", icon: "gearshape") { appState.selectedSidebarItem = .settings }
        }
    }

    private func navButton(_ title: String, icon: String, target: SidebarItem) -> some View {
        Button { appState.selectedSidebarItem = target } label: {
            HStack { Image(systemName: icon).frame(width: 20); Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption2) }
                .font(.caption.bold()).padding(9)
                .background(appState.selectedSidebarItem == target ? cyan.opacity(0.18) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(appState.selectedSidebarItem == target ? cyan.opacity(0.65) : Color.clear))
        }.buttonStyle(.plain)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 20); Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption2) }
                .font(.caption).padding(.vertical, 5)
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    private func statusRow(_ title: String, value: String, icon: String, good: Bool) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(cyan); Text(title).font(.caption.bold()); Spacer(); Text(value).font(.caption).foregroundStyle(good ? .green : .orange) }
        .padding(.vertical, 4)
    }

    private func flowNode(_ title: String, icon: String, active: Bool, green: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3).foregroundStyle(active ? (green ? .green : cyan) : .secondary)
            Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(active ? .primary : .secondary)
        }.frame(minWidth: 64)
    }

    private var flowLine: some View { Rectangle().fill(cyan.opacity(0.55)).frame(height: 1).frame(maxWidth: .infinity) }

    private func logRow(_ tag: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top) { Text(tag).font(.system(.caption2, design: .monospaced).bold()).foregroundStyle(color).frame(width: 62, alignment: .leading); Text(text).font(.system(.caption2, design: .monospaced)).lineLimit(1) }
    }

    private var commandBackground: some View {
        ZStack {
            LinearGradient(colors: [deep, Color(red: 0.005, green: 0.07, blue: 0.16), deep], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let step: CGFloat = 32
                var path = Path()
                stride(from: CGFloat.zero, through: size.width, by: step).forEach { x in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
                stride(from: CGFloat.zero, through: size.height, by: step).forEach { y in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(path, with: .color(cyan.opacity(0.055)), lineWidth: 0.5)
            }
        }
    }

    private var panelBackground: some View { RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.015, green: 0.07, blue: 0.14).opacity(0.92)) }
    private var panelBorder: some View { RoundedRectangle(cornerRadius: 8).stroke(cyan.opacity(0.6), lineWidth: 1) }
}

private struct HUDPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.15, green: 0.78, blue: 1))
            content
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.012, green: 0.055, blue: 0.12).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.05, green: 0.7, blue: 1).opacity(0.55), lineWidth: 1))
        .shadow(color: Color.cyan.opacity(0.06), radius: 8)
    }
}

private struct HUDIconButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28) }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.cyan.opacity(0.4)))
    }
}
#endif
