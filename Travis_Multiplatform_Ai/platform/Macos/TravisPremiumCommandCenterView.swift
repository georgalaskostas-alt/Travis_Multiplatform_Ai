#if os(macOS)
import SwiftUI

struct TravisPremiumCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var telemetry = TravisSystemTelemetry()
    @State private var learning = TravisLearningService.shared
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
                            navigationRail.frame(width: 190)
                            VStack(spacing: 10) {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(spacing: 10) {
                                        systemStatus
                                        coreModules
                                        systemMetrics
                                        resourceMonitor
                                    }.frame(width: 315)
                                    aiCore.frame(width: 525, height: 535)
                                    VStack(spacing: 10) {
                                        currentMission
                                        taskPipeline
                                        missionActivity
                                        quickActions
                                    }.frame(width: 440)
                                }
                                HStack(alignment: .top, spacing: 10) {
                                    taskFlowBottom
                                    learningPanel
                                    systemWave
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(minWidth: max(1510, geo.size.width), minHeight: max(930, geo.size.height), alignment: .topLeading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { telemetry.start(); learning.refresh(); spin = true; pulse = true }
        .onDisappear { telemetry.stop() }
        .sheet(isPresented: $showingChat) { ChatView(appState: appState).frame(minWidth: 820, minHeight: 620) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                HexBadgeShape().fill(cyan.opacity(0.12)).frame(width: 52, height: 48)
                HexBadgeShape().stroke(cyan.opacity(0.95), lineWidth: 1.6).frame(width: 52, height: 48)
                Text("T").font(.system(size: 29, weight: .black)).foregroundStyle(cyan).shadow(color: cyan, radius: 13)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("TRAVIS").font(.system(size: 28, weight: .black, design: .rounded)).tracking(3)
                Text("AI COMMAND CENTER").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(cyan)
            }
            statusPill("SYSTEM OPERATIONAL", color: .green)
            Spacer()
            headerMetric("CPU", telemetry.cpuPercent, cyan)
            headerMetric("RAM", telemetry.memoryPercent, .purple)
            headerMetric("DISK", telemetry.diskPercent, .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI COST").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Text(String(format: "$%.4f", learning.estimatedSpendUSD)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            }.frame(width: 78)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Date.now, style: .time).font(.system(size: 18, weight: .bold, design: .monospaced))
                Text("UPTIME \(telemetry.uptime)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
            premiumIconButton("magnifyingglass") { appState.selectedSidebarItem = .history }
            premiumIconButton("gearshape.fill") { appState.selectedSidebarItem = .settings }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(PremiumPanelShape(cut: 18).fill(panel.opacity(0.97)))
        .overlay(PremiumPanelShape(cut: 18).stroke(cyan.opacity(0.86), lineWidth: 1.4))
        .shadow(color: cyan.opacity(0.18), radius: 16)
    }

    private var navigationRail: some View {
        VStack(spacing: 10) {
            premiumPanel("NAVIGATION", icon: "dot.scope") {
                railButton("DASHBOARD", "square.grid.2x2.fill") { }
                railButton("CHAT", "message.fill") { showingChat = true }
                railButton("TASKS", "checklist") { appState.selectedSidebarItem = .tasks }
                railButton("HISTORY", "clock.arrow.circlepath") { appState.selectedSidebarItem = .history }
                railButton("PERMISSIONS", "lock.shield.fill") { appState.selectedSidebarItem = .permissions }
                railButton("SETTINGS", "gearshape.fill") { appState.selectedSidebarItem = .settings }
            }
            premiumPanel("QUICK ACCESS", icon: "bolt.fill") {
                railButton("NEW MISSION", "plus.circle.fill") { showingChat = true; appState.chatInput = "/plan " }
                railButton("NEW PROJECT", "folder.badge.plus") { showingChat = true; appState.chatInput = "Φτιάξε project " }
                railButton("SYSTEM SCAN", "magnifyingglass.circle") { showingChat = true; appState.chatInput = "Έλεγξε την κατάσταση του συστήματος" }
                railButton("VOICE COMMAND", "mic.fill") { appState.toggleListening() }
            }
            voiceControl
            premiumPanel("SYSTEM SIGNAL", icon: "waveform") {
                signalWave.frame(height: 72)
                dataLine("STATE", appState.isBusy ? "WORKING" : "STABLE", appState.isBusy ? .orange : .green)
            }
            Spacer(minLength: 0)
        }
    }

    private var voiceControl: some View {
        premiumPanel("VOICE CONTROL", icon: "waveform") {
            Button { appState.toggleListening() } label: {
                VStack(spacing: 7) {
                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .stroke(cyan.opacity(0.24 + Double(i) * 0.16), style: StrokeStyle(lineWidth: 1.5, dash: i == 1 ? [4, 5] : []))
                                .frame(width: CGFloat(92-i*17), height: CGFloat(92-i*17))
                                .rotationEffect(.degrees(spin ? Double((i+1)*120) : 0))
                                .animation(.linear(duration: Double(10+i*4)).repeatForever(autoreverses: false), value: spin)
                        }
                        Circle().fill(cyan.opacity(appState.isListening ? 0.22 : 0.08)).frame(width: 50, height: 50)
                        Image(systemName: appState.isListening ? "waveform" : "mic.fill").font(.system(size: 23, weight: .bold)).foregroundStyle(cyan).shadow(color: cyan, radius: 11)
                    }
                    Text(appState.isListening ? "LISTENING" : "TAP TO SPEAK").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(appState.isListening ? .green : cyan)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
        }
    }

    private var systemStatus: some View {
        premiumPanel("SYSTEM OVERVIEW", icon: "server.rack") {
            statusRow("AI ENGINE", appState.isInternetEnabled ? "ONLINE" : "LOCAL", "sparkles", .green)
            statusRow("DATA ENGINE", "ACTIVE", "externaldrive.connected.to.line.below", .green)
            statusRow("MEMORY CORE", "ACTIVE", "memorychip", .green)
            statusRow("VERIFIER", appState.isBusy ? "MONITORING" : "READY", "checkmark.shield", .green)
        }
    }

    private var coreModules: some View {
        premiumPanel("CORE MODULES", icon: "square.grid.3x2") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                moduleTile("AI ENGINE", "brain.head.profile", .cyan)
                moduleTile("DATA", "cylinder.split.1x2", .cyan)
                moduleTile("MEMORY", "memorychip", .cyan)
                moduleTile("VERIFIER", "checkmark.shield", .green)
                moduleTile("PLANNER", "point.3.connected.trianglepath.dotted", .cyan)
                moduleTile("EXECUTOR", "bolt.fill", .purple)
            }
        }
    }

    private var systemMetrics: some View {
        premiumPanel("SYSTEM METRICS", icon: "gauge.with.dots.needle.50percent") {
            HStack(spacing: 9) {
                circularGauge(value: telemetry.cpuPercent, label: "CPU", tint: cyan)
                circularGauge(value: telemetry.memoryPercent, label: "RAM", tint: .purple)
                circularGauge(value: telemetry.diskPercent, label: "DSK", tint: .orange)
            }.frame(height: 78)
        }
    }

    private var resourceMonitor: some View {
        premiumPanel("RESOURCE MONITOR", icon: "chart.xyaxis.line") {
            HStack(spacing: 7) {
                miniChart("CPU", telemetry.cpuPercent, cyan)
                miniChart("RAM", telemetry.memoryPercent, .purple)
                miniChart("DISK", telemetry.diskPercent, .orange)
            }
        }
    }

    private var aiCore: some View {
        ZStack {
            coreGrid

            // Continuous energy rails: each orbit has a bright moving head and a tail
            // that fades smoothly behind it. No dashed central rings.
            energyTrailOrbit(diameter: 492, lineWidth: 3.4, duration: 11.0, phase: 0, tint: cyan, clockwise: true)
            energyTrailOrbit(diameter: 458, lineWidth: 2.7, duration: 14.0, phase: 74, tint: cyan, clockwise: false)
            energyTrailOrbit(diameter: 424, lineWidth: 2.2, duration: 17.0, phase: 151, tint: blue, clockwise: true)
            energyTrailOrbit(diameter: 390, lineWidth: 2.0, duration: 20.0, phase: 223, tint: .purple, clockwise: false)
            energyTrailOrbit(diameter: 356, lineWidth: 1.8, duration: 16.0, phase: 307, tint: cyan, clockwise: true)

            // Quiet full rings underneath the moving energy trails for depth.
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .stroke(i < 3 ? cyan.opacity(0.20) : blue.opacity(0.12), lineWidth: i == 0 ? 1.5 : 1.0)
                    .frame(width: CGFloat(486 - i * 48), height: CGFloat(486 - i * 48))
            }

            ForEach(0..<32, id: \.self) { i in
                Capsule()
                    .fill(i % 7 == 0 ? Color.purple.opacity(0.95) : cyan.opacity(i % 4 == 0 ? 1.0 : 0.34))
                    .frame(width: 3, height: i % 4 == 0 ? 20 : 8)
                    .offset(y: -248)
                    .rotationEffect(.degrees(Double(i)*11.25))
            }

            Circle()
                .fill(RadialGradient(colors: [cyan.opacity(0.34), navy.opacity(0.98)], center: .center, startRadius: 0, endRadius: 100))
                .frame(width: 190, height: 190)
                .overlay(Circle().stroke(cyan, lineWidth: 2.2))
                .shadow(color: cyan.opacity(pulse ? 1.0 : 0.4), radius: pulse ? 36 : 16)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 5) {
                Text("TRAVIS").font(.system(size: 38, weight: .black, design: .rounded)).tracking(2.5)
                Text("AI CORE").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(cyan)
                Text(coreState).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(appState.isBusy ? .orange : .green)
                Image(systemName: "waveform").foregroundStyle(cyan)
            }

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    coreChip("PLANNER", appState.isProcessing, cyan)
                    coreChip("EXECUTOR", appState.isBusy, .purple)
                    coreChip("VERIFIER", appState.isBusy, .green)
                    coreChip("MEMORY", true, .orange)
                }.padding(.bottom, 4)
            }
        }
    }

    private func energyTrailOrbit(
        diameter: CGFloat,
        lineWidth: CGFloat,
        duration: Double,
        phase: Double,
        tint: Color,
        clockwise: Bool
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let direction = clockwise ? 1.0 : -1.0
            let angle = direction * ((time.truncatingRemainder(dividingBy: duration) / duration) * 360.0) + phase

            ZStack {
                Circle()
                    .trim(from: 0.00, to: 0.42)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: tint.opacity(0.03), location: 0.12),
                                .init(color: tint.opacity(0.12), location: 0.32),
                                .init(color: tint.opacity(0.40), location: 0.68),
                                .init(color: tint.opacity(0.95), location: 0.96),
                                .init(color: .white.opacity(0.95), location: 1.00)
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .shadow(color: tint.opacity(0.78), radius: 7)
                    .rotationEffect(.degrees(angle))

                Circle()
                    .fill(.white)
                    .frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                    .shadow(color: tint, radius: 9)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(angle + 151.2))
            }
            .frame(width: diameter, height: diameter)
        }
    }

    private var currentMission: some View {
        let task = activeRuntimeTask
        let done = task?.plan.steps.filter { $0.status == .completed }.count ?? 0
        let total = task?.plan.steps.count ?? 0
        let progress = total > 0 ? Double(done)/Double(total) : 0
        return premiumPanel("MISSION CONTROL", icon: "scope") {
            Text(task?.title ?? "Awaiting mission").font(.system(size: 13, weight: .bold)).lineLimit(1)
            Text(task?.plan.summary.isEmpty == false ? task!.plan.summary : appState.lastResponseSummary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            HStack { ProgressView(value: progress).tint(cyan); Text("\(Int(progress*100))%").font(.system(size: 10, weight: .bold, design: .monospaced)) }
            HStack { dataLine("STATUS", task?.status.rawValue.uppercased() ?? "READY", task?.status == .failed ? .red : .green); dataLine("STEPS", "\(done)/\(total)", cyan) }
        }
    }

    private var taskPipeline: some View {
        premiumPanel("MISSION FLOW", icon: "arrow.triangle.branch") {
            HStack(spacing: 2) {
                flowNode("RECEIVED", "tray.and.arrow.down.fill", true)
                flowConnector
                flowNode("PLANNING", "brain.head.profile", appState.isProcessing)
                flowConnector
                flowNode("EXECUTING", "bolt.fill", appState.isBusy)
                flowConnector
                flowNode("VERIFYING", "checkmark.shield", appState.isBusy)
                flowConnector
                flowNode("COMPLETED", "checkmark.circle.fill", !appState.isBusy, .green)
            }
        }
    }

    private var missionActivity: some View {
        let events = appState.taskRuntime.tasks.flatMap(\.events).sorted { $0.createdAt > $1.createdAt }.prefix(6)
        return premiumPanel("LIVE ACTIVITY", icon: "list.bullet.rectangle") {
            if events.isEmpty {
                Text("No activity yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(events), id: \.id) { e in
                    HStack(spacing: 7) {
                        Circle().fill(e.type == .failed ? Color.red : Color.purple).frame(width: 6, height: 6)
                        Text(e.type.rawValue.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(e.type == .failed ? .red : .purple).frame(width: 78, alignment: .leading)
                        Text(e.message).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        premiumPanel("QUICK ACTIONS", icon: "bolt.circle") {
            HStack(spacing: 6) {
                compactButton("NEW TASK", "plus.circle") { showingChat = true; appState.chatInput = "/plan " }
                compactButton("NEW PROJECT", "folder.badge.plus") { showingChat = true; appState.chatInput = "Φτιάξε project " }
                compactButton("VOICE", "mic") { appState.toggleListening() }
            }
        }
    }

    private var taskFlowBottom: some View {
        premiumPanel("TASK FLOW", icon: "point.3.filled.connected.trianglepath.dotted") {
            HStack(spacing: 3) {
                flowNode("RECEIVED", "circle", true)
                flowConnector
                flowNode("PLAN", "circle", appState.isProcessing)
                flowConnector
                flowNode("RUN", "circle", appState.isBusy)
                flowConnector
                flowNode("VERIFY", "circle", appState.isBusy)
                flowConnector
                flowNode("DONE", "checkmark.circle", !appState.isBusy, .green)
            }
        }.frame(maxWidth: .infinity)
    }

    private var learningPanel: some View {
        premiumPanel("TRAVIS LEARNING", icon: "brain.fill") {
            dataLine("AI REQUESTS", "\(learning.totalAIRequests)", cyan)
            dataLine("SUCCESS", String(format: "%.0f%%", learning.successRate*100), .green)
            dataLine("LEARNED ROUTES", "\(learning.learnedRoutes)", .purple)
            dataLine("TOKENS", "\(learning.totalTokens)", cyan)
            dataLine("EST. COST", String(format: "$%.4f", learning.estimatedSpendUSD), .orange)
            Text(learning.bestKnownRoute).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text("CONFIDENCE").font(.system(size: 8, design: .monospaced))
                ProgressView(value: learning.confidence).tint(cyan)
                Text("\(Int(learning.confidence*100))%").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(cyan)
            }
        }.frame(width: 330)
    }

    private var systemWave: some View {
        premiumPanel("SYSTEM SIGNAL", icon: "waveform") {
            signalWave.frame(height: 82)
            HStack {
                Text("CPU \(Int(telemetry.cpuPercent))%")
                Spacer()
                Text("RAM \(Int(telemetry.memoryPercent))%")
                Spacer()
                Text("DISK \(Int(telemetry.diskPercent))%")
            }.font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
        }.frame(width: 390)
    }

    private var signalWave: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var p = Path()
                let mid = size.height/2
                for x in stride(from: 0.0, through: size.width, by: 3.0) {
                    let n = x/size.width
                    let y = mid + sin(n*18+t*2.4)*10 + sin(n*47+t*1.3)*4
                    if x == 0 { p.move(to: CGPoint(x:x,y:y)) } else { p.addLine(to: CGPoint(x:x,y:y)) }
                }
                context.stroke(p, with: .color(cyan.opacity(0.98)), lineWidth: 1.9)
                context.stroke(p, with: .color(cyan.opacity(0.18)), lineWidth: 8)
            }
        }
    }

    private var activeRuntimeTask: AgentTask? {
        appState.taskRuntime.tasks.first { [.running,.planning,.waitingForApproval,.waitingForDependency].contains($0.status) } ?? appState.taskRuntime.tasks.first
    }
    private var coreState: String { appState.isProcessing ? "PROCESSING" : appState.isBusy ? "EXECUTING" : "ONLINE" }

    private var coreGrid: some View {
        Canvas { context,size in
            let c = CGPoint(x:size.width/2,y:size.height/2)
            for r in stride(from:CGFloat(60),through:255,by:26) {
                context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:r*2,height:r*2)), with: .color(cyan.opacity(0.065)), lineWidth: 0.75)
            }
            for a in stride(from:0.0,to:360.0,by:15.0) {
                let rad = a * .pi/180
                var p = Path()
                p.move(to:c)
                p.addLine(to:CGPoint(x:c.x+cos(rad)*255,y:c.y+sin(rad)*255))
                context.stroke(p, with: .color(cyan.opacity(0.035)), lineWidth: 0.65)
            }
        }
    }

    private var premiumBackground: some View {
        ZStack {
            LinearGradient(colors:[navy,Color(red:0.002,green:0.055,blue:0.13),navy],startPoint:.topLeading,endPoint:.bottomTrailing)

            Canvas { context,size in
                let grid:CGFloat = 30
                var p = Path()
                stride(from:CGFloat.zero,through:size.width,by:grid).forEach { x in p.move(to:CGPoint(x:x,y:0)); p.addLine(to:CGPoint(x:x,y:size.height)) }
                stride(from:CGFloat.zero,through:size.height,by:grid).forEach { y in p.move(to:CGPoint(x:0,y:y)); p.addLine(to:CGPoint(x:size.width,y:y)) }
                context.stroke(p, with: .color(cyan.opacity(0.042)), lineWidth: 0.55)
            }

            ambientGlowField

            RadialGradient(colors:[cyan.opacity(0.08),.clear],center:.center,startRadius:20,endRadius:680)
        }.ignoresSafeArea()
    }

    private var ambientGlowField: some View {
        GeometryReader { geo in
            let nodes: [(CGFloat, CGFloat, CGFloat, Color)] = [
                (0.09, 0.17, 86, cyan),
                (0.22, 0.74, 56, blue),
                (0.38, 0.13, 44, .purple),
                (0.52, 0.82, 68, cyan),
                (0.67, 0.24, 50, blue),
                (0.79, 0.66, 78, .purple),
                (0.91, 0.34, 46, cyan),
                (0.87, 0.87, 58, blue)
            ]

            TimelineView(.animation(minimumInterval: 0.18)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        let breathe = 0.88 + 0.12 * sin(t * (0.7 + Double(index) * 0.06) + Double(index))
                        ZStack {
                            Circle()
                                .fill(RadialGradient(colors: [node.3.opacity(0.24), node.3.opacity(0.06), .clear], center: .center, startRadius: 0, endRadius: node.2 / 2))
                                .frame(width: node.2, height: node.2)
                                .scaleEffect(breathe)
                                .blur(radius: 2.5)
                            Circle()
                                .stroke(node.3.opacity(0.14), lineWidth: 0.8)
                                .frame(width: node.2 * 0.46, height: node.2 * 0.46)
                            Circle()
                                .fill(node.3.opacity(0.72))
                                .frame(width: 3.5, height: 3.5)
                                .shadow(color: node.3, radius: 8)
                        }
                        .position(x: geo.size.width * node.0, y: geo.size.height * node.1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func premiumPanel<Content:View>(_ title:String, icon:String, @ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                Image(systemName:icon).font(.system(size:9))
                Text(title).tracking(1.1)
                Spacer()
                HStack(spacing:2) { ForEach(0..<3,id:\.self) { _ in Circle().fill(cyan.opacity(0.72)).frame(width:4,height:4) } }
            }
            .font(.system(size:9,weight:.bold,design:.monospaced))
            .foregroundStyle(cyan)
            content()
        }
        .padding(11)
        .background(PremiumPanelShape(cut:12).fill(panel.opacity(0.94)))
        .overlay(PremiumPanelShape(cut:12).stroke(cyan.opacity(0.74),lineWidth:1.2))
        .overlay(alignment:.topLeading) { Rectangle().fill(cyan.opacity(0.95)).frame(width:60,height:2) }
        .shadow(color:cyan.opacity(0.14),radius:12)
    }

    private func railButton(_ title:String,_ icon:String,action:@escaping()->Void)->some View {
        Button(action:action) {
            HStack {
                Image(systemName:icon).frame(width:20).foregroundStyle(cyan)
                Text(title)
                Spacer()
                Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(cyan.opacity(0.7))
            }
            .font(.system(size:9,weight:.bold,design:.monospaced))
            .padding(.vertical,5)
            .contentShape(Rectangle())
        }.buttonStyle(PremiumHUDButtonStyle(cyan:cyan))
    }

    private func compactButton(_ title:String,_ icon:String,action:@escaping()->Void)->some View {
        Button(action:action) {
            HStack(spacing:4) { Image(systemName:icon); Text(title) }
                .font(.system(size:8,weight:.bold,design:.monospaced))
                .frame(maxWidth:.infinity)
                .padding(.vertical,6)
        }.buttonStyle(PremiumHUDButtonStyle(cyan:cyan))
    }

    private func premiumIconButton(_ icon:String,action:@escaping()->Void)->some View {
        Button(action:action) { Image(systemName:icon).frame(width:30,height:30).foregroundStyle(cyan) }
            .buttonStyle(PremiumHUDButtonStyle(cyan:cyan))
    }

    private func statusPill(_ text:String,color:Color)->some View {
        HStack(spacing:5) {
            Circle().fill(color).frame(width:6,height:6).shadow(color:color,radius:5)
            Text(text)
        }
        .font(.system(size:8,weight:.bold,design:.monospaced))
        .foregroundStyle(color)
        .padding(.horizontal,8).padding(.vertical,5)
        .background(Capsule().fill(color.opacity(0.09)))
        .overlay(Capsule().stroke(color.opacity(0.42), lineWidth: 1))
    }

    private func headerMetric(_ label:String,_ value:Double,_ tint:Color)->some View {
        VStack(alignment:.leading,spacing:2) {
            Text(label).font(.system(size:7,weight:.bold,design:.monospaced)).foregroundStyle(.secondary)
            Text("\(Int(value))%").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundStyle(tint)
            ProgressView(value:value,total:100).tint(tint)
        }.frame(width:70)
    }

    private func statusRow(_ name:String,_ value:String,_ icon:String,_ color:Color)->some View {
        HStack {
            Image(systemName:icon).foregroundStyle(cyan).frame(width:18)
            Text(name).font(.system(size:8,weight:.bold,design:.monospaced))
            Spacer()
            Circle().fill(color).frame(width:6,height:6).shadow(color:color,radius:5)
            Text(value).font(.system(size:8,weight:.bold,design:.monospaced)).foregroundStyle(color)
        }.padding(.vertical,3)
    }

    private func dataLine(_ name:String,_ value:String,_ color:Color)->some View {
        HStack {
            Text(name).font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(color)
        }.padding(.vertical,2)
    }

    private func moduleTile(_ title:String,_ icon:String,_ tint:Color)->some View {
        VStack(spacing:5) {
            Image(systemName:icon).font(.system(size:18)).foregroundStyle(tint).shadow(color:tint.opacity(0.7),radius:6)
            Text(title).font(.system(size:7,weight:.bold,design:.monospaced))
            Text("ACTIVE").font(.system(size:6,weight:.bold,design:.monospaced)).foregroundStyle(.green)
        }
        .frame(maxWidth:.infinity,minHeight:62)
        .background(PremiumPanelShape(cut:6).fill(tint.opacity(0.05)))
        .overlay(PremiumPanelShape(cut:6).stroke(tint.opacity(0.44), lineWidth: 1))
    }

    private func flowNode(_ title:String,_ icon:String,_ active:Bool,_ color:Color?=nil)->some View {
        let tint = color ?? cyan
        return VStack(spacing:4) {
            ZStack {
                Circle().fill(tint.opacity(active ? 0.18:0.04)).frame(width:38,height:38)
                Circle().stroke(tint.opacity(active ? 0.9:0.2), lineWidth: 1.4).frame(width:38,height:38)
                Image(systemName:icon).font(.system(size:12)).foregroundStyle(active ? tint:.secondary)
            }
            Text(title).font(.system(size:7,weight:.bold,design:.monospaced)).foregroundStyle(active ? .primary:.secondary)
        }.frame(width:67)
    }

    private var flowConnector:some View {
        HStack(spacing:1) {
            Rectangle().fill(cyan.opacity(0.42)).frame(height:2)
            Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(cyan.opacity(0.75))
        }.frame(maxWidth:.infinity)
    }

    private func circularGauge(value:Double,label:String,tint:Color)->some View {
        ZStack {
            Circle().stroke(tint.opacity(0.14),lineWidth:7)
            Circle().trim(from:0,to:min(max(value/100,0),1))
                .stroke(tint,style:StrokeStyle(lineWidth:7,lineCap:.round))
                .rotationEffect(.degrees(-90))
                .shadow(color:tint.opacity(0.85),radius:5)
            VStack(spacing:1) {
                Text(label).font(.system(size:7,weight:.bold,design:.monospaced))
                Text("\(Int(value))%").font(.system(size:10,weight:.bold,design:.monospaced))
            }.foregroundStyle(tint)
        }.frame(maxWidth:.infinity)
    }

    private func miniChart(_ label:String,_ value:Double,_ tint:Color)->some View {
        VStack(alignment:.leading,spacing:3) {
            Text(label).font(.system(size:7,weight:.bold,design:.monospaced))
            GeometryReader { _ in
                Canvas { context,size in
                    var p=Path()
                    for x in stride(from:0.0,through:size.width,by:4) {
                        let n=x/max(size.width,1)
                        let y=size.height-(sin(n*14+value/9)*0.18+0.48)*size.height
                        if x==0 { p.move(to:CGPoint(x:x,y:y)) } else { p.addLine(to:CGPoint(x:x,y:y)) }
                    }
                    context.stroke(p,with:.color(tint.opacity(0.18)),lineWidth:6)
                    context.stroke(p,with:.color(tint),lineWidth:1.7)
                }
            }.frame(height:45)
            Text("\(Int(value))%").font(.system(size:8,weight:.bold,design:.monospaced)).foregroundStyle(tint)
        }.frame(maxWidth:.infinity)
    }

    private func coreChip(_ text:String,_ active:Bool,_ tint:Color)->some View {
        VStack(spacing:3) {
            Image(systemName:active ? "circle.inset.filled":"circle").foregroundStyle(tint)
            Text(text).font(.system(size:7,weight:.bold,design:.monospaced))
            Text(active ? "ACTIVE":"READY").font(.system(size:6,weight:.bold,design:.monospaced)).foregroundStyle(active ? .green:tint)
        }
        .padding(.horizontal,11).padding(.vertical,7)
        .background(PremiumPanelShape(cut:6).fill(tint.opacity(0.09)))
        .overlay(PremiumPanelShape(cut:6).stroke(tint.opacity(0.5), lineWidth: 1))
    }
}

private struct PremiumPanelShape:Shape {
    let cut:CGFloat
    func path(in rect:CGRect)->Path {
        var p=Path()
        p.move(to:CGPoint(x:cut,y:0))
        p.addLine(to:CGPoint(x:rect.maxX-8,y:0))
        p.addLine(to:CGPoint(x:rect.maxX,y:8))
        p.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY-cut))
        p.addLine(to:CGPoint(x:rect.maxX-cut,y:rect.maxY))
        p.addLine(to:CGPoint(x:8,y:rect.maxY))
        p.addLine(to:CGPoint(x:0,y:rect.maxY-8))
        p.addLine(to:CGPoint(x:0,y:cut))
        p.closeSubpath()
        return p
    }
}

private struct HexBadgeShape:Shape {
    func path(in rect:CGRect)->Path {
        var p=Path()
        p.move(to:CGPoint(x:rect.width*0.22,y:0))
        p.addLine(to:CGPoint(x:rect.width*0.78,y:0))
        p.addLine(to:CGPoint(x:rect.width,y:rect.height*0.5))
        p.addLine(to:CGPoint(x:rect.width*0.78,y:rect.height))
        p.addLine(to:CGPoint(x:rect.width*0.22,y:rect.height))
        p.addLine(to:CGPoint(x:0,y:rect.height*0.5))
        p.closeSubpath()
        return p
    }
}

private struct PremiumHUDButtonStyle:ButtonStyle {
    let cyan:Color
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .padding(.horizontal,6)
            .background(PremiumPanelShape(cut:5).fill(cyan.opacity(configuration.isPressed ? 0.22:0.055)))
            .overlay(PremiumPanelShape(cut:5).stroke(cyan.opacity(configuration.isPressed ? 0.8:0.30),lineWidth:1))
            .scaleEffect(configuration.isPressed ? 0.985:1)
            .animation(.easeOut(duration:0.12),value:configuration.isPressed)
    }
}
#endif
