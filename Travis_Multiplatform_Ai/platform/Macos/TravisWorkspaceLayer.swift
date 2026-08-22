#if os(macOS)
import SwiftUI

struct TravisWorkspaceLayer<Base: View>: View {
    @Bindable var appState: TRAVISAppState
    @Binding private var openFCCQuickAccess: Bool
    let base: Base

    @State private var windows: [WorkspaceWindow] = []
    @State private var nextZ: Double = 10
    @State private var actionRouter = TravisUIActionRouter.shared

    init(
        appState: TRAVISAppState,
        openFCCQuickAccess: Binding<Bool> = .constant(false),
        @ViewBuilder base: () -> Base
    ) {
        self.appState = appState
        self._openFCCQuickAccess = openFCCQuickAccess
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
        .onAppear {
            consumeFCCQuickAccessRequest()
            consumePendingUIAction()
        }
        .onChange(of: openFCCQuickAccess) { _, requested in
            guard requested else { return }
            consumeFCCQuickAccessRequest()
        }
        .onChange(of: actionRouter.pendingRequest?.id) { _, _ in
            consumePendingUIAction()
        }
    }

    private var launcher: some View {
        VStack(spacing: 7) {
            launchButton(.chat, "message.fill")
            launchButton(.history, "clock.arrow.circlepath")
            launchButton(.tasks, "checklist")
            launchButton(.fcc, "waveform.path.ecg", prominent: true)
            launchButton(.memory, "memorychip.fill")
        }
        .padding(8)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.cyan.opacity(0.48), lineWidth: 1.2))
        .shadow(color: .cyan.opacity(0.18), radius: 14)
        .help("Quick access to TRAVIS workspaces")
    }

    private func launchButton(_ kind: TravisWorkspaceID, _ icon: String, prominent: Bool = false) -> some View {
        Button { appState.performUIAction(.openWorkspace(kind)) } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(prominent ? .green : .cyan)
                .frame(width: 32, height: 32)
                .background(Circle().fill((prominent ? Color.green : Color.cyan).opacity(prominent ? 0.12 : 0.08)))
                .overlay(Circle().stroke((prominent ? Color.green : Color.cyan).opacity(prominent ? 0.62 : 0.35), lineWidth: prominent ? 1.4 : 1))
                .shadow(color: prominent ? .green.opacity(0.22) : .clear, radius: 7)
        }
        .buttonStyle(.plain)
        .help(kind.tooltip)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder
    private func floating(_ window: WorkspaceWindow, in size: CGSize) -> some View {
        let maximized = window.mode == .maximized
        let width = maximized ? max(640, size.width - 36) : min(max(760, size.width * 0.66), 1120)
        let height = maximized ? max(520, size.height - 36) : min(max(560, size.height * 0.70), 820)

        VStack(spacing: 0) {
            windowBar(window)
            Rectangle().fill(LinearGradient(colors: [.clear, .cyan.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            windowContent(window.kind).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .background(LinearGradient(colors: [Color(red: 0.006, green: 0.035, blue: 0.095), Color(red: 0.002, green: 0.012, blue: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LinearGradient(colors: [.white.opacity(0.28), .cyan.opacity(0.82), .blue.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.8))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.07), lineWidth: 0.6).padding(3))
        .shadow(color: .black.opacity(0.88), radius: 32, y: 18)
        .shadow(color: .cyan.opacity(0.17), radius: 22)
        .zIndex(window.z)
        .onTapGesture { appState.performUIAction(.bringWorkspaceToFront(window.kind)) }
    }

    private func windowBar(_ window: WorkspaceWindow) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.cyan.opacity(0.07)).frame(width: 28, height: 28)
                RoundedRectangle(cornerRadius: 7).stroke(.cyan.opacity(0.34), lineWidth: 1).frame(width: 28, height: 28)
                Image(systemName: window.kind.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.cyan)
            }
            .help(window.kind.tooltip)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.kind.title).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.1)
                Text("TRAVIS WORKSPACE").font(.system(size: 6, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(.cyan.opacity(0.72))
            }
            Spacer()
            circleControl("minus", tooltip: "Minimize \(window.kind.title)") {
                appState.performUIAction(.minimizeWorkspace(window.kind))
            }
            circleControl(
                window.mode == .maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                tooltip: window.mode == .maximized ? "Restore \(window.kind.title)" : "Maximize \(window.kind.title)"
            ) {
                appState.performUIAction(window.mode == .maximized ? .restoreWorkspace(window.kind) : .maximizeWorkspace(window.kind))
            }
            circleControl("xmark", tooltip: "Close \(window.kind.title)") {
                appState.performUIAction(.closeWorkspace(window.kind))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(LinearGradient(colors: [.white.opacity(0.055), Color(red:0.003,green:0.025,blue:0.082).opacity(0.96), .black.opacity(0.74)], startPoint: .top, endPoint: .bottom))
    }

    private func circleControl(_ icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.cyan).frame(width: 25, height: 25)
                .background(Circle().fill(.cyan.opacity(0.055)))
                .overlay(Circle().stroke(.cyan.opacity(0.30), lineWidth: 0.9))
                .shadow(color: .cyan.opacity(0.08), radius: 4)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    @ViewBuilder
    private func windowContent(_ kind: TravisWorkspaceID) -> some View {
        switch kind {
        case .chat:
            TravisPremiumWorkspaceChatView(appState: appState)
        case .history:
            TravisPremiumHistoryView(appState: appState)
        case .tasks:
            TravisPremiumTasksView(appState: appState)
        case .fcc:
            TravisPremiumFCCView(appState: appState)
        case .memory:
            TravisPremiumMemoryView()
        case .dashboard, .permissions, .settings:
            EmptyView()
        }
    }

    private var minimizedDock: some View {
        HStack(spacing: 8) {
            ForEach(windows.filter { $0.mode == .minimized }) { window in
                Button {
                    appState.performUIAction(.restoreWorkspace(window.kind))
                } label: {
                    Label(window.kind.title, systemImage: window.kind.icon)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(LinearGradient(colors: [.white.opacity(0.04), .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)))
                        .overlay(Capsule().stroke(.cyan.opacity(0.46), lineWidth: 1))
                        .shadow(color: .cyan.opacity(0.12), radius: 8)
                }
                .buttonStyle(.plain)
                .help("Restore \(window.kind.title)")
            }
        }
    }

    private func consumeFCCQuickAccessRequest() {
        guard openFCCQuickAccess else { return }
        appState.performUIAction(.openWorkspace(.fcc))
        openFCCQuickAccess = false
    }

    private func consumePendingUIAction() {
        guard let request = actionRouter.pendingRequest else { return }
        handle(request.action)
        actionRouter.consume(request.id)
    }

    private func handle(_ action: TravisUIAction) {
        switch action {
        case .openWorkspace(let kind):
            guard kind.isFloatingWorkspace else { return }
            open(kind)
        case .closeWorkspace(let kind):
            close(kind)
        case .minimizeWorkspace(let kind):
            setMode(kind, .minimized)
        case .maximizeWorkspace(let kind):
            setMode(kind, .maximized)
        case .restoreWorkspace(let kind):
            setMode(kind, .normal)
            bringToFront(kind)
        case .bringWorkspaceToFront(let kind):
            bringToFront(kind)
        case .newMission, .newProject, .systemScan, .toggleVoice:
            break
        }
    }

    private func open(_ kind: TravisWorkspaceID) {
        if let existing = windows.first(where: { $0.kind == kind }) {
            setMode(existing.id, .normal)
            bringToFront(existing.id)
            return
        }
        nextZ += 1
        windows.append(WorkspaceWindow(kind: kind, z: nextZ))
    }

    private func close(_ kind: TravisWorkspaceID) {
        windows.removeAll { $0.kind == kind }
    }

    private func setMode(_ kind: TravisWorkspaceID, _ mode: WorkspaceWindow.Mode) {
        guard let index = windows.firstIndex(where: { $0.kind == kind }) else { return }
        windows[index].mode = mode
    }

    private func bringToFront(_ kind: TravisWorkspaceID) {
        guard let index = windows.firstIndex(where: { $0.kind == kind }) else { return }
        nextZ += 1
        windows[index].z = nextZ
    }

    private func setMode(_ id: UUID, _ mode: WorkspaceWindow.Mode) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].mode = mode
    }

    private func bringToFront(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        nextZ += 1
        windows[index].z = nextZ
    }
}

private extension TravisWorkspaceID {
    var isFloatingWorkspace: Bool {
        switch self {
        case .chat, .history, .tasks, .fcc, .memory: return true
        case .dashboard, .permissions, .settings: return false
        }
    }

    var title: String {
        switch self {
        case .dashboard: return "DASHBOARD"
        case .chat: return "TRAVIS CHAT"
        case .history: return "CONVERSATION HISTORY"
        case .tasks: return "TASK CONTROL"
        case .fcc: return "FCC SYSTEM"
        case .memory: return "LEARNING & MEMORY"
        case .permissions: return "PERMISSIONS"
        case .settings: return "SETTINGS"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .chat: return "message.fill"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "checklist"
        case .fcc: return "waveform.path.ecg"
        case .memory: return "memorychip.fill"
        case .permissions: return "lock.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tooltip: String {
        switch self {
        case .dashboard: return "Show TRAVIS command center"
        case .chat: return "Open TRAVIS chat workspace"
        case .history: return "Open conversation history"
        case .tasks: return "Open autonomous task control"
        case .fcc: return "Open FCC Assistant — local read-only process intelligence"
        case .memory: return "Open TRAVIS learning and memory"
        case .permissions: return "Open TRAVIS permissions"
        case .settings: return "Open TRAVIS settings"
        }
    }
}

private struct WorkspaceWindow: Identifiable {
    enum Mode: Equatable { case normal, maximized, minimized }
    let id = UUID()
    let kind: TravisWorkspaceID
    var mode: Mode = .normal
    var z: Double
}
#endif
