#if os(macOS)
import SwiftUI

struct TravisPremiumCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var telemetry = TravisSystemTelemetry()
    @State private var learning = TravisLearningService.shared
    @State private var pulse = false
    @State private var showingChat = false

    private let cyan = Color(red: 0.06, green: 0.84, blue: 1)
    private let electric = Color(red: 0.16, green: 0.48, blue: 1)
    private let navy = Color(red: 0.002, green: 0.014, blue: 0.05)
    private let panel = Color(red: 0.006, green: 0.045, blue: 0.105)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                premiumBackground
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 12) {
                        header
                        HStack(alignment: .top, spacing: 12) {
                            navigationRail.frame(width: 200)
                            VStack(spacing: 12) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(spacing: 12) { systemStatus; coreModules; systemMetrics; resourceMonitor }.frame(width: 320)
                                    aiCore.frame(width: 540, height: 545)
                                    VStack(spacing: 12) { currentMission; taskPipeline; missionActivity; quickActions }.frame(width: 445)
                                }
                                HStack(alignment: .top, spacing: 12) { taskFlowBottom; learningPanel; systemWave }
                            }
                        }
                    }
                    .padding(14)
                    .frame(minWidth: max(1540, geo.size.width), minHeight: max(940, geo.size.height), alignment: .topLeading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { telemetry.start(); learning.refresh(); pulse = true }
        .onDisappear { telemetry.stop() }
        .sheet(isPresented: $showingChat) { ChatView(appState: appState).frame(minWidth: 820, minHeight: 620) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                PremiumHex().fill(cyan.opacity(0.13)).frame(width: 54, height: 50)
                PremiumHex().stroke(cyan, lineWidth: 3).frame(width: 54, height: 50).shadow(color: cyan.opacity(0.8), radius: 8)
                Text("T").font(.system(size: 29, weight: .black)).foregroundStyle(.white).shadow(color: cyan, radius: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("TRAVIS").font(.system(size: 29, weight: .black, design: .rounded)).tracking(3)
                Text("AI COMMAND CENTER").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.6).foregroundStyle(cyan)
            }
            statusPill("SYSTEM OPERATIONAL", .green)
            Spacer()
            headerMetric("CPU", telemetry.cpuPercent, cyan)
            headerMetric("RAM", telemetry.memoryPercent, .purple)
            headerMetric("DISK", telemetry.diskPercent, .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI COST").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Text(String(format: "$%.4f", learning.estimatedSpendUSD)).font(.system(size: 12, weight: .black, design: .monospaced)).foregroundStyle(.green)
            }.frame(width: 82)
            VStack(alignment: .trailing) {
                Text(Date.now, style: .time).font(.system(size: 18, weight: .black, design: .monospaced))
                Text("UPTIME \(telemetry.uptime)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
            iconButton("magnifyingglass") { appState.selectedSidebarItem = .history }
            iconButton("gearshape.fill") { appState.selectedSidebarItem = .settings }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(PremiumPanelShape(cut: 20).fill(panel.opacity(0.98)))
        .overlay(PremiumPanelShape(cut: 20).stroke(cyan.opacity(0.9), lineWidth: 2.4))
        .overlay(PremiumPanelShape(cut: 20).stroke(.white.opacity(0.16), lineWidth: 0.7).padding(3))
        .shadow(color: cyan.opacity(0.24), radius: 18)
    }

    private var navigationRail: some View {
        VStack(spacing: 12) {
            hudPanel("NAVIGATION", "dot.scope") {
                rail("DASHBOARD", "square.grid.2x2.fill") { }
                rail("CHAT", "message.fill") { showingChat = true }
                rail("TASKS", "checklist") { appState.selectedSidebarItem = .tasks }
                rail("HISTORY", "clock.arrow.circlepath") { appState.selectedSidebarItem = .history }
                rail("PERMISSIONS", "lock.shield.fill") { appState.selectedSidebarItem = .permissions }
                rail("SETTINGS", "gearshape.fill") { appState.selectedSidebarItem = .settings }
            }
            hudPanel("QUICK ACCESS", "bolt.fill") {
                rail("NEW MISSION", "plus.circle.fill") { showingChat = true; appState.chatInput = "/plan " }
                rail("NEW PROJECT", "folder.badge.plus") { showingChat = true; appState.chatInput = "Φτιάξε project " }
                rail("SYSTEM SCAN", "magnifyingglass.circle") { showingChat = true; appState.chatInput = "Έλεγξε την κατάσταση του συστήματος" }
                rail("VOICE", "mic.fill") { appState.toggleListening() }
            }
            hudPanel("VOICE CONTROL", "waveform") {
                Button { appState.toggleListening() } label: {
                    ZStack {
                        Circle().stroke(cyan.opacity(0.22), lineWidth: 7).frame(width: 92, height: 92)
                        Circle().stroke(cyan.opacity(0.85), lineWidth: 3).frame(width: 72, height: 72).shadow(color: cyan, radius: 8)
                        Circle().fill(cyan.opacity(appState.isListening ? 0.24 : 0.08)).frame(width: 52, height: 52)
                        Image(systemName: appState.isListening ? "waveform" : "mic.fill").font(.system(size: 23, weight: .bold)).foregroundStyle(cyan).shadow(color: cyan, radius: 11)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
                Text(appState.isListening ? "LISTENING" : "VOICE STANDBY").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(appState.isListening ? .green : cyan).frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
    }

    private var systemStatus: some View {
        hudPanel("SYSTEM OVERVIEW", "server.rack") {
            statusRow("AI ENGINE", appState.isInternetEnabled ? "ONLINE" : "LOCAL", .green)
            statusRow("DATA ENGINE", "ACTIVE", .green)
            statusRow("MEMORY CORE", "ACTIVE", .green)
            statusRow("VERIFIER", appState.isBusy ? "MONITORING" : "READY", .green)
        }
    }

    private var coreModules: some View {
        hudPanel("CORE MODULES", "square.grid.3x2") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                module("AI", "brain.head.profile", cyan); module("DATA", "cylinder", cyan); module("MEMORY", "memorychip", cyan)
                module("VERIFY", "checkmark.shield", .green); module("PLAN", "point.3.connected.trianglepath.dotted", cyan); module("EXECUTE", "bolt.fill", .purple)
            }
        }
    }

    private var systemMetrics: some View {
        hudPanel("SYSTEM METRICS", "gauge.with.dots.needle.50percent") {
            HStack(spacing: 12) { gauge(telemetry.cpuPercent, "CPU", cyan); gauge(telemetry.memoryPercent, "RAM", .purple); gauge(telemetry.diskPercent, "DSK", .orange) }.frame(height: 82)
        }
    }

    private var resourceMonitor: some View {
        hudPanel("RESOURCE MONITOR", "chart.xyaxis.line") {
            signalWave.frame(height: 70)
            HStack { data("CPU", "\(Int(telemetry.cpuPercent))%", cyan); data("RAM", "\(Int(telemetry.memoryPercent))%", .purple); data("DISK", "\(Int(telemetry.diskPercent))%", .orange) }
        }
    }

    private var aiCore: some View {
        ZStack {
            coreGrid
            energyOrbit(500, 11.0, 0, cyan, true)
            energyOrbit(462, 14.0, 70, cyan, false)
            energyOrbit(424, 17.0, 145, electric, true)
            energyOrbit(386, 20.0, 220, .purple, false)
            energyOrbit(348, 16.0, 300, cyan, true)

            ForEach(0..<5, id: \.self) { i in
                Circle().stroke(i < 2 ? cyan.opacity(0.30) : electric.opacity(0.17), lineWidth: CGFloat(4.5 - Double(i) * 0.55)).frame(width: CGFloat(492-i*48), height: CGFloat(492-i*48)).shadow(color: cyan.opacity(0.18), radius: 5)
            }

            ForEach(0..<28, id: \.self) { i in
                Capsule().fill(i % 6 == 0 ? Color.purple : cyan.opacity(i % 3 == 0 ? 1 : 0.5)).frame(width: 5, height: i % 3 == 0 ? 22 : 10).offset(y: -250).rotationEffect(.degrees(Double(i)*12.86)).shadow(color: cyan.opacity(0.45), radius: 3)
            }

            Circle().fill(RadialGradient(colors: [.white.opacity(0.12), cyan.opacity(0.38), navy], center: .center, startRadius: 0, endRadius: 102)).frame(width: 194, height: 194)
                .overlay(Circle().stroke(cyan, lineWidth: 6))
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.2).padding(7))
                .shadow(color: cyan.opacity(pulse ? 1 : 0.5), radius: pulse ? 38 : 18)
                .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 5) {
                Text("TRAVIS").font(.system(size: 40, weight: .black, design: .rounded)).tracking(3)
                Text("AI CORE").font(.system(size: 13, weight: .black, design: .monospaced)).foregroundStyle(cyan)
                Text(coreState).font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(appState.isBusy ? .orange : .green)
                Image(systemName: "waveform").foregroundStyle(cyan).shadow(color: cyan, radius: 7)
            }

            VStack { Spacer(); HStack(spacing: 9) { coreChip("PLANNER", appState.isProcessing, cyan); coreChip("EXECUTOR", appState.isBusy, .purple); coreChip("VERIFIER", appState.isBusy, .green); coreChip("MEMORY", true, .orange) }.padding(.bottom, 2) }
        }
    }

    private func energyOrbit(_ diameter: CGFloat, _ duration: Double, _ phase: Double, _ tint: Color, _ clockwise: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 50.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let direction = clockwise ? 1.0 : -1.0
            let angle = direction * ((t.truncatingRemainder(dividingBy: duration) / duration) * 360) + phase
            ZStack {
                Circle().trim(from: 0, to: 0.48)
                    .stroke(AngularGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: tint.opacity(0.08), location: 0.18), .init(color: tint.opacity(0.35), location: 0.48), .init(color: tint.opacity(0.85), location: 0.78), .init(color: .white, location: 1)
                    ], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .shadow(color: tint.opacity(0.85), radius: 10)
                    .rotationEffect(.degrees(angle))
                Circle().trim(from: 0.22, to: 0.48).stroke(.white.opacity(0.20), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(angle))
                Circle().fill(.white).frame(width: 13, height: 13).shadow(color: tint, radius: 14).offset(y: -diameter/2).rotationEffect(.degrees(angle + 172.8))
            }.frame(width: diameter, height: diameter)
        }
    }

    private var currentMission: some View {
        let task = activeTask
        let done = task?.plan.steps.filter { $0.status == .completed }.count ?? 0
        let total = task?.plan.steps.count ?? 0
        let progress = total > 0 ? Double(done)/Double(total) : 0
        return hudPanel("MISSION CONTROL", "scope") {
            Text(task?.title ?? "Awaiting mission").font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(task?.plan.summary.isEmpty == false ? task!.plan.summary : appState.lastResponseSummary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            HStack { ProgressView(value: progress).tint(cyan); Text("\(Int(progress*100))%").font(.system(size: 11, weight: .black, design: .monospaced)).foregroundStyle(cyan) }
            HStack { data("STATUS", task?.status.rawValue.uppercased() ?? "READY", task?.status == .failed ? .red : .green); data("STEPS", "\(done)/\(total)", cyan) }
        }
    }

    private var taskPipeline: some View { hudPanel("MISSION FLOW", "arrow.triangle.branch") { HStack(spacing: 2) { flow("RECEIVE", true); connector; flow("PLAN", appState.isProcessing); connector; flow("EXECUTE", appState.isBusy); connector; flow("VERIFY", appState.isBusy); connector; flow("DONE", !appState.isBusy, .green) } } }

    private var missionActivity: some View {
        let events = appState.taskRuntime.tasks.flatMap(\.events).sorted { $0.createdAt > $1.createdAt }.prefix(6)
        return hudPanel("LIVE ACTIVITY", "list.bullet.rectangle") {
            if events.isEmpty { Text("No activity yet").font(.caption).foregroundStyle(.secondary) }
            else { ForEach(Array(events), id: \.id) { e in HStack(spacing: 8) { Circle().fill(e.type == .failed ? Color.red : cyan).frame(width: 7, height: 7).shadow(color: e.type == .failed ? .red : cyan, radius: 5); Text(e.type.rawValue.uppercased()).font(.system(size: 8, weight: .black, design: .monospaced)).foregroundStyle(e.type == .failed ? .red : cyan).frame(width: 78, alignment: .leading); Text(e.message).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1); Spacer() } } }
        }
    }

    private var quickActions: some View { hudPanel("QUICK ACTIONS", "bolt.circle") { HStack(spacing: 7) { compact("NEW TASK", "plus.circle") { showingChat = true; appState.chatInput = "/plan " }; compact("PROJECT", "folder.badge.plus") { showingChat = true; appState.chatInput = "Φτιάξε project " }; compact("VOICE", "mic") { appState.toggleListening() } } } }
    private var taskFlowBottom: some View { hudPanel("TASK FLOW", "point.3.filled.connected.trianglepath.dotted") { HStack(spacing: 3) { flow("RECEIVED", true); connector; flow("PLAN", appState.isProcessing); connector; flow("RUN", appState.isBusy); connector; flow("VERIFY", appState.isBusy); connector; flow("DONE", !appState.isBusy, .green) } }.frame(maxWidth: .infinity) }

    private var learningPanel: some View {
        hudPanel("TRAVIS LEARNING", "brain.fill") {
            data("AI REQUESTS", "\(learning.totalAIRequests)", cyan); data("SUCCESS", String(format: "%.0f%%", learning.successRate*100), .green); data("LEARNED ROUTES", "\(learning.learnedRoutes)", .purple); data("TOKENS", "\(learning.totalTokens)", cyan); data("EST. COST", String(format: "$%.4f", learning.estimatedSpendUSD), .orange)
            Text(learning.bestKnownRoute).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack { Text("CONFIDENCE").font(.system(size: 8, design: .monospaced)); ProgressView(value: learning.confidence).tint(cyan); Text("\(Int(learning.confidence*100))%").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(cyan) }
        }.frame(width: 335)
    }

    private var systemWave: some View { hudPanel("SYSTEM SIGNAL", "waveform") { signalWave.frame(height: 86); HStack { data("CPU", "\(Int(telemetry.cpuPercent))%", cyan); data("RAM", "\(Int(telemetry.memoryPercent))%", .purple); data("DISK", "\(Int(telemetry.diskPercent))%", .orange) } }.frame(width: 395) }

    private var signalWave: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in Canvas { context, size in let t=timeline.date.timeIntervalSinceReferenceDate; var p=Path(); let mid=size.height/2; for x in stride(from:0.0, through:size.width, by:3.0) { let n=x/max(size.width,1); let y=mid+sin(n*18+t*2.4)*10+sin(n*47+t*1.3)*4; if x==0 { p.move(to:CGPoint(x:x,y:y)) } else { p.addLine(to:CGPoint(x:x,y:y)) } }; context.stroke(p,with:.color(cyan.opacity(0.16)),lineWidth:10); context.stroke(p,with:.color(cyan),lineWidth:3.2) } }
    }

    private var coreGrid: some View { Canvas { context,size in let c=CGPoint(x:size.width/2,y:size.height/2); for r in stride(from:CGFloat(60),through:255,by:26) { context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:r*2,height:r*2)),with:.color(cyan.opacity(0.09)),lineWidth:1.2) }; for a in stride(from:0.0,to:360.0,by:15.0) { let rad=a * .pi/180; var p=Path(); p.move(to:c); p.addLine(to:CGPoint(x:c.x+cos(rad)*255,y:c.y+sin(rad)*255)); context.stroke(p,with:.color(cyan.opacity(0.05)),lineWidth:1) } } }

    private var premiumBackground: some View {
        ZStack {
            LinearGradient(colors:[navy,Color(red:0.002,green:0.06,blue:0.145),navy],startPoint:.topLeading,endPoint:.bottomTrailing)
            Canvas { context,size in let grid:CGFloat=32; var p=Path(); stride(from:CGFloat.zero,through:size.width,by:grid).forEach{x in p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height))}; stride(from:CGFloat.zero,through:size.height,by:grid).forEach{y in p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y))}; context.stroke(p,with:.color(cyan.opacity(0.055)),lineWidth:0.8) }
            ambientNodes
            RadialGradient(colors:[cyan.opacity(0.10),.clear],center:.center,startRadius:30,endRadius:700)
        }.ignoresSafeArea()
    }

    private var ambientNodes: some View {
        GeometryReader { geo in TimelineView(.animation(minimumInterval:0.2)) { timeline in let t=timeline.date.timeIntervalSinceReferenceDate; ZStack { ForEach(0..<10,id:\.self) { i in let x=[0.08,0.18,0.31,0.43,0.56,0.68,0.79,0.91,0.74,0.26][i]; let y=[0.18,0.72,0.29,0.84,0.15,0.61,0.32,0.76,0.91,0.48][i]; let size=CGFloat(38+(i%4)*15); let s=0.88+0.12*sin(t*0.65+Double(i)); ZStack { Circle().fill(RadialGradient(colors:[cyan.opacity(0.32),cyan.opacity(0.08),.clear],center:.center,startRadius:0,endRadius:size/2)).frame(width:size,height:size).scaleEffect(s).blur(radius:2); Circle().stroke(cyan.opacity(0.22),lineWidth:1.5).frame(width:size*0.45,height:size*0.45); Circle().fill(.white.opacity(0.8)).frame(width:4,height:4).shadow(color:cyan,radius:9) }.position(x:geo.size.width*x,y:geo.size.height*y) } } } }.allowsHitTesting(false)
    }

    private var activeTask: AgentTask? { appState.taskRuntime.tasks.first { [.running,.planning,.waitingForApproval,.waitingForDependency].contains($0.status) } ?? appState.taskRuntime.tasks.first }
    private var coreState:String { appState.isProcessing ? "PROCESSING" : appState.isBusy ? "EXECUTING" : "ONLINE" }

    private func hudPanel<Content:View>(_ title:String,_ icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:7) { Image(systemName:icon); Text(title).tracking(1.2); Spacer(); Rectangle().fill(LinearGradient(colors:[.clear,cyan,.white],startPoint:.leading,endPoint:.trailing)).frame(width:48,height:3).shadow(color:cyan,radius:5) }.font(.system(size:9,weight:.black,design:.monospaced)).foregroundStyle(cyan)
            content()
        }
        .padding(12)
        .background(PremiumPanelShape(cut:13).fill(LinearGradient(colors:[panel.opacity(0.98),Color(red:0.01,green:0.07,blue:0.14).opacity(0.93)],startPoint:.topLeading,endPoint:.bottomTrailing)))
        .overlay(PremiumPanelShape(cut:13).stroke(cyan.opacity(0.78),lineWidth:2.2))
        .overlay(PremiumPanelShape(cut:13).stroke(.white.opacity(0.13),lineWidth:0.7).padding(3))
        .overlay(alignment:.topLeading){Rectangle().fill(cyan).frame(width:72,height:3).shadow(color:cyan,radius:7)}
        .shadow(color:cyan.opacity(0.17),radius:13)
    }

    private func rail(_ title:String,_ icon:String,action:@escaping()->Void)->some View { Button(action:action){HStack{Image(systemName:icon).frame(width:21).foregroundStyle(cyan);Text(title);Spacer();Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(cyan)}.font(.system(size:9,weight:.bold,design:.monospaced)).padding(.vertical,6)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func compact(_ title:String,_ icon:String,action:@escaping()->Void)->some View { Button(action:action){HStack(spacing:4){Image(systemName:icon);Text(title)}.font(.system(size:8,weight:.black,design:.monospaced)).frame(maxWidth:.infinity).padding(.vertical,6)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func iconButton(_ icon:String,action:@escaping()->Void)->some View { Button(action:action){Image(systemName:icon).frame(width:31,height:31).foregroundStyle(cyan)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func statusPill(_ text:String,_ color:Color)->some View { HStack(spacing:6){Circle().fill(color).frame(width:7,height:7).shadow(color:color,radius:6);Text(text)}.font(.system(size:8,weight:.black,design:.monospaced)).foregroundStyle(color).padding(.horizontal,9).padding(.vertical,6).background(Capsule().fill(color.opacity(0.10))).overlay(Capsule().stroke(color.opacity(0.55),lineWidth:1.5)) }
    private func headerMetric(_ label:String,_ value:Double,_ tint:Color)->some View { VStack(alignment:.leading,spacing:2){Text(label).font(.system(size:7,weight:.bold,design:.monospaced)).foregroundStyle(.secondary);Text("\(Int(value))%").font(.system(size:12,weight:.black,design:.monospaced)).foregroundStyle(tint);ProgressView(value:value,total:100).tint(tint)}.frame(width:72) }
    private func statusRow(_ name:String,_ value:String,_ tint:Color)->some View { HStack{Circle().stroke(cyan.opacity(0.6),lineWidth:2).frame(width:10,height:10);Text(name).font(.system(size:8,weight:.bold,design:.monospaced));Spacer();Circle().fill(tint).frame(width:7,height:7).shadow(color:tint,radius:6);Text(value).font(.system(size:8,weight:.black,design:.monospaced)).foregroundStyle(tint)}.padding(.vertical,4) }
    private func data(_ key:String,_ value:String,_ tint:Color)->some View { HStack{Text(key).font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary);Spacer();Text(value).font(.system(size:9,weight:.black,design:.monospaced)).foregroundStyle(tint)}.padding(.vertical,2) }
    private func module(_ title:String,_ icon:String,_ tint:Color)->some View { VStack(spacing:5){Image(systemName:icon).font(.system(size:18,weight:.bold)).foregroundStyle(tint).shadow(color:tint,radius:7);Text(title).font(.system(size:7,weight:.black,design:.monospaced));Text("ACTIVE").font(.system(size:6,weight:.black,design:.monospaced)).foregroundStyle(.green)}.frame(maxWidth:.infinity,minHeight:64).background(PremiumPanelShape(cut:7).fill(tint.opacity(0.06))).overlay(PremiumPanelShape(cut:7).stroke(tint.opacity(0.62),lineWidth:1.8)).shadow(color:tint.opacity(0.10),radius:5) }
    private func gauge(_ value:Double,_ label:String,_ tint:Color)->some View { ZStack{Circle().stroke(tint.opacity(0.18),lineWidth:9);Circle().trim(from:0,to:min(max(value/100,0),1)).stroke(tint,style:StrokeStyle(lineWidth:9,lineCap:.round)).rotationEffect(.degrees(-90)).shadow(color:tint.opacity(0.9),radius:7);VStack(spacing:1){Text(label).font(.system(size:7,weight:.black,design:.monospaced));Text("\(Int(value))%").font(.system(size:10,weight:.black,design:.monospaced))}.foregroundStyle(tint)}.frame(maxWidth:.infinity) }
    private func flow(_ title:String,_ active:Bool,_ tint:Color?=nil)->some View { let c=tint ?? cyan; return VStack(spacing:4){ZStack{Circle().fill(c.opacity(active ? 0.20:0.04)).frame(width:40,height:40);Circle().stroke(c.opacity(active ? 0.95:0.22),lineWidth:3).frame(width:40,height:40).shadow(color:c.opacity(active ? 0.5:0),radius:5);Circle().fill(active ? c:.secondary).frame(width:8,height:8)};Text(title).font(.system(size:7,weight:.black,design:.monospaced)).foregroundStyle(active ? .primary:.secondary)}.frame(width:68) }
    private var connector:some View { HStack(spacing:0){Rectangle().fill(cyan.opacity(0.7)).frame(height:3);Image(systemName:"chevron.right").font(.system(size:8,weight:.black)).foregroundStyle(cyan)}.frame(maxWidth:.infinity).shadow(color:cyan.opacity(0.4),radius:3) }
    private func coreChip(_ title:String,_ active:Bool,_ tint:Color)->some View { VStack(spacing:3){Circle().fill(active ? tint:tint.opacity(0.45)).frame(width:8,height:8).shadow(color:tint,radius:6);Text(title).font(.system(size:7,weight:.black,design:.monospaced));Text(active ? "ACTIVE":"READY").font(.system(size:6,weight:.black,design:.monospaced)).foregroundStyle(active ? .green:tint)}.padding(.horizontal,12).padding(.vertical,8).background(PremiumPanelShape(cut:7).fill(tint.opacity(0.10))).overlay(PremiumPanelShape(cut:7).stroke(tint.opacity(0.65),lineWidth:1.8)).shadow(color:tint.opacity(0.12),radius:6) }
}

private struct PremiumPanelShape:Shape { let cut:CGFloat; func path(in r:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:cut,y:0));p.addLine(to:CGPoint(x:r.maxX-9,y:0));p.addLine(to:CGPoint(x:r.maxX,y:9));p.addLine(to:CGPoint(x:r.maxX,y:r.maxY-cut));p.addLine(to:CGPoint(x:r.maxX-cut,y:r.maxY));p.addLine(to:CGPoint(x:9,y:r.maxY));p.addLine(to:CGPoint(x:0,y:r.maxY-9));p.addLine(to:CGPoint(x:0,y:cut));p.closeSubpath();return p} }
private struct PremiumHex:Shape { func path(in r:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:r.width*0.22,y:0));p.addLine(to:CGPoint(x:r.width*0.78,y:0));p.addLine(to:CGPoint(x:r.width,y:r.height*0.5));p.addLine(to:CGPoint(x:r.width*0.78,y:r.height));p.addLine(to:CGPoint(x:r.width*0.22,y:r.height));p.addLine(to:CGPoint(x:0,y:r.height*0.5));p.closeSubpath();return p} }
private struct PremiumButton:ButtonStyle { let cyan:Color; func makeBody(configuration:Configuration)->some View{configuration.label.padding(.horizontal,7).background(PremiumPanelShape(cut:6).fill(cyan.opacity(configuration.isPressed ? 0.24:0.055))).overlay(PremiumPanelShape(cut:6).stroke(cyan.opacity(configuration.isPressed ? 0.95:0.42),lineWidth:1.5)).shadow(color:cyan.opacity(configuration.isPressed ? 0.25:0.06),radius:5).scaleEffect(configuration.isPressed ? 0.985:1)} }
#endif
