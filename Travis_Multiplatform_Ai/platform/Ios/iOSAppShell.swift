import SwiftUI

struct iOSAppShell: View {
    @Bindable var appState: TRAVISAppState

    @State private var activeSheet: MobileSheet?
    @State private var pulse = false

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let electric = Color(red: 0.16, green: 0.48, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    var body: some View {
        NavigationStack {
            ZStack {
                premiumBackground

                ScrollView {
                    VStack(spacing: 14) {
                        header
                        aiCore
                        systemOverview
                        quickAccess
                        missionPanel
                        coreModules
                        statusPanel
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { bottomDock }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            pulse = true
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                sheetContent(sheet)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                activeSheet = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                            }
                            .accessibilityLabel("Close")
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var premiumBackground: some View {
        ZStack {
            navy.ignoresSafeArea()
            LinearGradient(
                colors: [Color.black, navy, panel.opacity(0.84), navy],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [cyan.opacity(0.12), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(cyan.opacity(0.10))
                    .frame(width: 46, height: 46)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(cyan, lineWidth: 1.5)
                    .frame(width: 46, height: 46)
                    .shadow(color: cyan.opacity(0.6), radius: 7)
                Text("T")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: cyan, radius: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("TRAVIS")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .tracking(2)
                Text("AI COMMAND CENTER")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()
            statusPill(appState.isBusy ? "BUSY" : "ONLINE", appState.isBusy ? .orange : .green)

            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(cyan)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .overlay(Circle().stroke(cyan.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var aiCore: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.clear
                    .frame(width: 258, height: 258)

                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(
                            i == 0 ? cyan.opacity(0.55) : electric.opacity(0.18),
                            lineWidth: i == 0 ? 2 : 1
                        )
                        .frame(
                            width: CGFloat(238 - i * 32),
                            height: CGFloat(238 - i * 32)
                        )
                }

                // Draw the moving arc directly from the stage centre instead of
                // rotating a trimmed SwiftUI Circle. This guarantees that the
                // orbit stays perfectly concentric on every animation frame.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius: CGFloat = 113
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: 7.0) / 7.0) * 360.0
                        let start = Angle.degrees(phase - 90)
                        let end = Angle.degrees(phase - 90 + 194.4)

                        var arc = Path()
                        arc.addArc(
                            center: center,
                            radius: radius,
                            startAngle: start,
                            endAngle: end,
                            clockwise: false
                        )

                        context.stroke(
                            arc,
                            with: .color(cyan),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                    }
                    .frame(width: 258, height: 258)
                    .allowsHitTesting(false)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.10), cyan.opacity(0.22), navy],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 154, height: 154)
                    .overlay(Circle().stroke(cyan, lineWidth: 3))
                    .shadow(color: cyan.opacity(pulse ? 0.72 : 0.28), radius: pulse ? 28 : 12)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: pulse
                    )

                VStack(spacing: 4) {
                    Text("TRAVIS")
                        .font(.system(size: 31, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                    Text("AI CORE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(cyan)
                    Text(appState.isBusy ? "PROCESSING" : "READY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(appState.isBusy ? .orange : .green)
                    Image(systemName: appState.isListening ? "waveform" : "waveform.path")
                        .foregroundStyle(cyan)
                        .shadow(color: cyan, radius: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 258)
            .clipped()

            HStack(spacing: 8) {
                coreMini("PLAN", "scope", appState.isProcessing ? "ACTIVE" : "READY", cyan)
                coreMini("EXEC", "bolt.fill", appState.isBusy ? "RUN" : "READY", .purple)
                coreMini("VERIFY", "checkmark.shield.fill", "READY", .green)
                coreMini("MEM", "memorychip.fill", "ACTIVE", .orange)
            }
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var systemOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SYSTEM OVERVIEW", "server.rack")
            HStack(spacing: 8) {
                statusTile("AI ENGINE", appState.isInternetEnabled ? "ONLINE" : "LOCAL", .green)
                statusTile("VOICE", appState.isListening ? "LISTENING" : "STANDBY", appState.isListening ? .green : cyan)
            }
            HStack(spacing: 8) {
                statusTile("RUNTIME", appState.isBusy ? "RUNNING" : "READY", appState.isBusy ? .orange : .green)
                statusTile("MEMORY", "ACTIVE", .green)
            }
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("QUICK ACCESS", "bolt.fill")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                quickButton("CHAT", "message.fill") { activeSheet = .chat }
                quickButton("TASKS", "checklist") {
                    appState.chatInput = "/tasks"
                    activeSheet = .chat
                }
                quickButton("HISTORY", "clock.arrow.circlepath") { activeSheet = .history }
                quickButton("PERMISSIONS", "lock.shield.fill") { activeSheet = .permissions }
                quickButton("NEW MISSION", "plus.circle.fill") {
                    appState.chatInput = "/plan "
                    activeSheet = .chat
                }
                quickButton("SYSTEM SCAN", "magnifyingglass.circle") {
                    appState.chatInput = "Έλεγξε την κατάσταση του συστήματος"
                    activeSheet = .chat
                }
                quickButton("VOICE", appState.isListening ? "waveform" : "mic.fill") {
                    appState.isListening.toggle()
                }
                quickButton("FCC", "waveform.path.ecg") {
                    appState.chatInput = "Άνοιξε το FCC Assistant μέσω του συνδεδεμένου Mac"
                    activeSheet = .chat
                }
            }
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var missionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CURRENT MISSION", "scope")
            Text(appState.isBusy ? "TRAVIS is executing an active task." : "No active mission")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(appState.lastResponseSummary.isEmpty ? "Ready for a new mission." : appState.lastResponseSummary)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var coreModules: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CORE MODULES", "square.grid.3x2")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                module("AI", "brain.head.profile", cyan)
                module("DATA", "cylinder", cyan)
                module("MEMORY", "memorychip", cyan)
                module("VERIFY", "checkmark.shield", .green)
                module("PLAN", "point.3.connected.trianglepath.dotted", cyan)
                module("EXECUTE", "bolt.fill", .purple)
            }
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("DEVICE LINK", "iphone.and.arrow.forward")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("IPHONE TRAVIS")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Mobile command interface")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill("ACTIVE", .green)
            }
        }
        .padding(12)
        .hudSurface(cyan: cyan, panel: panel)
    }

    private var bottomDock: some View {
        HStack(spacing: 6) {
            dockButton("HOME", "square.grid.2x2.fill") { activeSheet = nil }
            dockButton("CHAT", "message.fill") { activeSheet = .chat }
            dockButton("VOICE", appState.isListening ? "waveform" : "mic.fill") {
                appState.isListening.toggle()
            }
            dockButton("HISTORY", "clock.arrow.circlepath") { activeSheet = .history }
            dockButton("SETTINGS", "gearshape.fill") { activeSheet = .settings }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            LinearGradient(colors: [.clear, cyan.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: MobileSheet) -> some View {
        switch sheet {
        case .chat:
            ChatView(appState: appState)
                .navigationTitle("TRAVIS Chat")
        case .history:
            ChatHistoryView(appState: appState)
                .navigationTitle("History")
        case .permissions:
            PermissionsView(appState: appState)
                .navigationTitle("Permissions")
        case .settings:
            SettingsView(appState: appState)
                .navigationTitle("Settings")
        }
    }

    private func sectionTitle(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(cyan)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
            Spacer()
        }
    }

    private func statusPill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 8, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.8))
    }

    private func coreMini(_ title: String, _ icon: String, _ status: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14, weight: .bold))
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded))
            Text(status)
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.28), lineWidth: 0.8))
    }

    private func statusTile(_ title: String, _ status: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(status)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.22), lineWidth: 0.8))
    }

    private func quickButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(cyan)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.26), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func dockButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(cyan)
                Text(title)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func module(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.45), radius: 5)
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 0.8))
    }
}

private enum MobileSheet: String, Identifiable {
    case chat
    case history
    case permissions
    case settings

    var id: String { rawValue }
}

private extension View {
    func hudSurface(cyan: Color, panel: Color) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.05), panel.opacity(0.96), Color.black.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.18), cyan.opacity(0.52), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.72), radius: 14, y: 8)
            .shadow(color: cyan.opacity(0.07), radius: 9)
    }
}