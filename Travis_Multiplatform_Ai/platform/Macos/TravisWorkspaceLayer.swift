#if os(macOS)
import SwiftUI

struct TravisWorkspaceLayer<Base: View>: View {
    @Bindable var appState: TRAVISAppState
    let base: Base

    @State private var windows: [WorkspaceWindow] = []
    @State private var nextZ: Double = 10

    init(appState: TRAVISAppState, @ViewBuilder base: () -> Base) {
        self.appState = appState
        self.base = base()
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                base
                launcher
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 76)
                    .padding(.trailing, 18)

                ForEach(windows.filter { $0.mode != .minimized }.sorted { $0.z < $1.z }) { window in
                    floating(window, in: geo.size)
                }

                minimizedDock
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
            }
        }
    }

    private var launcher: some View {
        VStack(spacing: 7) {
            launchButton(.chat, "message.fill")
            launchButton(.history, "clock.arrow.circlepath")
            launchButton(.tasks, "checklist")
            launchButton(.fcc, "waveform.path.ecg")
            launchButton(.memory, "memorychip.fill")
        }
        .padding(8)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.cyan.opacity(0.48), lineWidth: 1.2))
        .shadow(color: .cyan.opacity(0.18), radius: 14)
    }

    private func launchButton(_ kind: WorkspaceKind, _ icon: String) -> some View {
        Button {
            open(kind)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.cyan.opacity(0.08)))
                .overlay(Circle().stroke(.cyan.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(kind.title)
    }

    @ViewBuilder
    private func floating(_ window: WorkspaceWindow, in size: CGSize) -> some View {
        let maximized = window.mode == .maximized
        let width = maximized ? max(640, size.width - 36) : min(max(760, size.width * 0.66), 1120)
        let height = maximized ? max(520, size.height - 36) : min(max(560, size.height * 0.70), 820)

        VStack(spacing: 0) {
            windowBar(window)
            Divider().overlay(.cyan.opacity(0.25))
            windowContent(window.kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .background(
            LinearGradient(colors: [Color(red: 0.006, green: 0.035, blue: 0.095), Color(red: 0.002, green: 0.012, blue: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LinearGradient(colors: [.white.opacity(0.24), .cyan.opacity(0.72), .blue.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6))
        .shadow(color: .black.opacity(0.85), radius: 32, y: 18)
        .shadow(color: .cyan.opacity(0.15), radius: 20)
        .zIndex(window.z)
        .onTapGesture { bringToFront(window.id) }
    }

    private func windowBar(_ window: WorkspaceWindow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: window.kind.icon).foregroundStyle(.cyan)
            Text(window.kind.title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.1)
            Spacer()
            circleControl("minus") { setMode(window.id, .minimized) }
            circleControl(window.mode == .maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                setMode(window.id, window.mode == .maximized ? .normal : .maximized)
            }
            circleControl("xmark") { close(window.id) }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white.opacity(0.025))
    }

    private func circleControl(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).frame(width: 25, height: 25)
                .background(Circle().fill(.white.opacity(0.05)))
                .overlay(Circle().stroke(.cyan.opacity(0.28), lineWidth: 0.8))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func windowContent(_ kind: WorkspaceKind) -> some View {
        switch kind {
        case .chat:
            ChatView(appState: appState)
        case .history:
            ChatHistoryView(appState: appState)
        case .tasks:
            VStack(alignment: .leading, spacing: 12) {
                Text("AUTONOMOUS TASKS").font(.headline).foregroundStyle(.cyan)
                List(appState.activeTasks) { task in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title).font(.headline)
                        Text(task.details).font(.caption).foregroundStyle(.secondary)
                        Text("\(task.status.rawValue) • \(task.priority.rawValue)").font(.caption2).foregroundStyle(.cyan)
                    }.padding(.vertical, 4)
                }.scrollContentBackground(.hidden)
            }.padding(16)
        case .fcc:
            FCCWorkspaceView(appState: appState)
        case .memory:
            ScrollView {
                Text(LocalIntelligenceMetrics.shared.diagnosticReport())
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
    }

    private var minimizedDock: some View {
        HStack(spacing: 8) {
            ForEach(windows.filter { $0.mode == .minimized }) { window in
                Button {
                    setMode(window.id, .normal)
                    bringToFront(window.id)
                } label: {
                    Label(window.kind.title, systemImage: window.kind.icon)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.72)))
                        .overlay(Capsule().stroke(.cyan.opacity(0.42), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private func open(_ kind: WorkspaceKind) {
        if let existing = windows.first(where: { $0.kind == kind }) {
            setMode(existing.id, .normal)
            bringToFront(existing.id)
            return
        }
        nextZ += 1
        windows.append(WorkspaceWindow(kind: kind, z: nextZ))
    }

    private func close(_ id: UUID) { windows.removeAll { $0.id == id } }
    private func setMode(_ id: UUID, _ mode: WorkspaceWindow.Mode) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].mode = mode
    }
    private func bringToFront(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        nextZ += 1; windows[index].z = nextZ
    }
}

private enum WorkspaceKind: String, Identifiable, CaseIterable {
    case chat, history, tasks, fcc, memory
    var id: String { rawValue }
    var title: String {
        switch self { case .chat: return "TRAVIS CHAT"; case .history: return "CONVERSATION HISTORY"; case .tasks: return "TASK CONTROL"; case .fcc: return "FCC SYSTEM"; case .memory: return "LEARNING & MEMORY" }
    }
    var icon: String {
        switch self { case .chat: return "message.fill"; case .history: return "clock.arrow.circlepath"; case .tasks: return "checklist"; case .fcc: return "waveform.path.ecg"; case .memory: return "memorychip.fill" }
    }
}

private struct WorkspaceWindow: Identifiable {
    enum Mode { case normal, maximized, minimized }
    let id = UUID()
    let kind: WorkspaceKind
    var mode: Mode = .normal
    var z: Double
}

private struct FCCWorkspaceView: View {
    @Bindable var appState: TRAVISAppState
    @State private var status = "Not checked"
    @State private var response = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FCC ASSISTANT").font(.system(size: 20, weight: .heavy, design: .rounded))
                    Text("Read-only FCC module • AI powered by TRAVIS").font(.caption).foregroundStyle(.cyan)
                }
                Spacer()
                Text(status).font(.caption.bold()).foregroundStyle(status.contains("ONLINE") ? .green : .orange)
            }

            HStack(spacing: 10) {
                Button("CHECK FCC") { checkStatus() }
                Button("DEMO SHIFT") { runCommand("FCC demo shift") }
                Button("ASK TRAVIS ABOUT FCC") {
                    openChatWith("FCC: ")
                }
                Button("SHIFT REPORT") {
                    openChatWith("FCC shift report: ")
                }
            }.buttonStyle(.bordered)

            ScrollView {
                Text(response.isEmpty ? "FCC output will appear here." : response)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.cyan.opacity(0.20)))

            if loading { ProgressView().controlSize(.small) }
        }
        .padding(18)
    }

    private func checkStatus() {
        loading = true
        Task { @MainActor in
            do {
                let capability = appState.orchestrator.capabilities.first { $0.id == "fcc_assistant" }
                guard let capability else { status = "FCC MODULE MISSING"; loading = false; return }
                let result = try await capability.handle(command: "FCC status", recentHistory: [])
                switch result {
                case .reply(let text): response = text; status = "FCC ONLINE"
                case .proposal: response = "FCC returned an unexpected proposal."; status = "CHECK FCC"
                case .none: response = "No FCC response."; status = "CHECK FCC"
                }
            } catch {
                response = error.localizedDescription; status = "FCC OFFLINE"
            }
            loading = false
        }
    }

    private func runCommand(_ command: String) {
        appState.chatInput = command
        appState.sendChat()
    }

    private func openChatWith(_ text: String) {
        appState.chatInput = text
    }
}
#endif
