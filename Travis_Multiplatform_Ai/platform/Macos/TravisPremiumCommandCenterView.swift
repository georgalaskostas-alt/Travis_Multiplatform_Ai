#if os(macOS)
import SwiftUI

struct TravisPremiumCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var telemetry = TravisSystemTelemetry()
    @State private var learning = TravisLearningService.shared
    @State private var pulse = false
    @State private var showingChat = false

    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let electric = Color(red: 0.16, green: 0.48, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

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
                                    aiCore.frame(width: 540, height: 730)
                                    VStack(spacing: 12) { currentMission; taskPipeline; missionActivity; quickActions }.frame(width: 445)
                                }
                                HStack(alignment: .top, spacing: 12) { taskFlowBottom; learningPanel; systemWave }
                            }
                        }
                    }
                    .padding(14)
                    .frame(minWidth: max(1540, geo.size.width), minHeight: max(1120, geo.size.height), alignment: .topLeading)
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
                PremiumHex().fill(cyan.opacity(0.10)).frame(width: 54, height: 50)
                PremiumHex().stroke(cyan, lineWidth: 2).frame(width: 54, height: 50).shadow(color: cyan.opacity(0.7), radius: 7)
                Text("T").font(.system(size: 29, weight: .heavy, design: .rounded)).foregroundStyle(.white).shadow(color: cyan, radius: 9)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("TRAVIS").font(.system(size: 29, weight: .heavy, design: .rounded)).tracking(2.2)
                Text("AI COMMAND CENTER").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.82))
            }
            statusPill("SYSTEM OPERATIONAL", .green)
            Spacer()
            headerMetric("CPU", telemetry.cpuPercent, cyan)
            headerMetric("RAM", telemetry.memoryPercent, .purple)
            headerMetric("DISK", telemetry.diskPercent, .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI COST").font(.system(size: 7, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Text(String(format: "$%.4f", learning.estimatedSpendUSD)).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.green)
            }.frame(width: 82)
            VStack(alignment: .trailing) {
                Text(Date.now, style: .time).font(.system(size: 18, weight: .bold, design: .rounded))
                Text("UPTIME \(telemetry.uptime)").font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            iconButton("magnifyingglass") { appState.selectedSidebarItem = .history }
            iconButton("gearshape.fill") { appState.selectedSidebarItem = .settings }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .background(PremiumPanelShape(cut: 20).fill(Color.black.opacity(0.78)).offset(y: 7))
        .background(PremiumPanelShape(cut: 20).fill(LinearGradient(colors: [.white.opacity(0.065), panel.opacity(0.98), navy.opacity(0.99)], startPoint: .top, endPoint: .bottom)))
        .overlay(PremiumPanelShape(cut: 20).stroke(LinearGradient(colors: [.white.opacity(0.38), cyan.opacity(0.82), electric.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.8))
        .overlay(PremiumPanelShape(cut: 20).stroke(.white.opacity(0.13), lineWidth: 0.65).padding(3))
        .overlay(alignment: .top) { LinearGradient(colors: [.white.opacity(0.38), cyan.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing).frame(height: 1.2).padding(.horizontal, 28) }
        .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, electric.opacity(0.18), cyan.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing).frame(height: 3).offset(y: 3) }
        .shadow(color: .black.opacity(0.98), radius: 20, y: 13)
        .shadow(color: cyan.opacity(0.16), radius: 16, y: -2)
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
                        Ellipse().fill(navy.opacity(0.92)).frame(width: 94, height: 20).blur(radius: 9).offset(y: 47)
                        Circle().stroke(cyan.opacity(0.16), lineWidth: 6).frame(width: 92, height: 92)
                        Circle().stroke(cyan.opacity(0.75), lineWidth: 2).frame(width: 72, height: 72).shadow(color: cyan, radius: 7)
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.14), cyan.opacity(appState.isListening ? 0.22 : 0.07), navy.opacity(0.88)], center: .topLeading, startRadius: 0, endRadius: 42)).frame(width: 52, height: 52)
                        Image(systemName: appState.isListening ? "waveform" : "mic.fill").font(.system(size: 23, weight: .bold)).foregroundStyle(cyan).shadow(color: cyan, radius: 10)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
                Text(appState.isListening ? "LISTENING" : "VOICE STANDBY").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(appState.isListening ? .green : cyan).frame(maxWidth: .infinity)
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
        VStack(spacing: 28) {
            ZStack {
                coreGrid
                energyOrbit(500, 11.0, 0, cyan, true)
                energyOrbit(462, 14.0, 70, cyan, false)
                energyOrbit(424, 17.0, 145, electric, true)
                energyOrbit(386, 20.0, 220, .purple, false)
                energyOrbit(348, 16.0, 300, cyan, true)
                ForEach(0..<5, id: \.self) { i in Circle().stroke(i < 2 ? cyan.opacity(0.24) : electric.opacity(0.13), lineWidth: CGFloat(4.2 - Double(i) * 0.5)).frame(width: CGFloat(492-i*48), height: CGFloat(492-i*48)).shadow(color: cyan.opacity(0.13), radius: 4) }
                ForEach(0..<28, id: \.self) { i in Capsule().fill(i % 6 == 0 ? Color.purple : cyan.opacity(i % 3 == 0 ? 1 : 0.45)).frame(width: 4, height: i % 3 == 0 ? 20 : 9).offset(y: -250).rotationEffect(.degrees(Double(i)*12.86)).shadow(color: cyan.opacity(0.35), radius: 3) }
                Circle().fill(RadialGradient(colors: [.white.opacity(0.08), cyan.opacity(0.30), navy], center: .center, startRadius: 0, endRadius: 102)).frame(width: 194, height: 194).overlay(Circle().stroke(cyan, lineWidth: 4)).overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 0.8).padding(7)).shadow(color: cyan.opacity(pulse ? 0.85 : 0.35), radius: pulse ? 34 : 16).animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: pulse)
                VStack(spacing: 4) {
                    Text("TRAVIS").font(.system(size: 40, weight: .heavy, design: .rounded)).tracking(2.2)
                    Text("AI CORE").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(cyan)
                    Text(coreState).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(appState.isBusy ? .orange : .green)
                    Image(systemName: "waveform").foregroundStyle(cyan).shadow(color: cyan, radius: 6)
                }
            }
            .frame(width: 540, height: 520)

            ZStack {
                CorePlatformShape().fill(Color.black.opacity(0.72)).frame(width: 500, height: 88).offset(y: 7)
                CorePlatformShape().fill(LinearGradient(colors: [.white.opacity(0.07), panel.opacity(0.82), navy.opacity(0.99)], startPoint: .top, endPoint: .bottom)).frame(width: 500, height: 88)
                    .overlay(CorePlatformShape().stroke(LinearGradient(colors: [.white.opacity(0.34), cyan.opacity(0.48), electric.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                    .overlay(CorePlatformShape().stroke(.white.opacity(0.08), lineWidth: 0.55).padding(3))
                    .shadow(color: .black.opacity(0.98), radius: 18, y: 13)
                    .shadow(color: cyan.opacity(0.08), radius: 12, y: -4)
                Ellipse().fill(navy.opacity(0.96)).frame(width: 460, height: 34).blur(radius: 12).offset(y: 38)
                HStack(spacing: 8) {
                    modulePedestal("PLANNER", "scope", appState.isProcessing ? "ACTIVE" : "READY", cyan)
                    modulePedestal("EXECUTOR", "bolt.fill", appState.isBusy ? "RUNNING" : "READY", .purple)
                    modulePedestal("VERIFIER", "checkmark.shield.fill", appState.isBusy ? "MONITORING" : "READY", .green)
                    modulePedestal("MEMORY", "memorychip.fill", "ACTIVE", .orange)
                }
                .offset(y: -20)
            }
            .frame(width: 520, height: 175)
        }
    }

    private func energyOrbit(_ diameter: CGFloat, _ duration: Double, _ phase: Double, _ tint: Color, _ clockwise: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 50.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let direction = clockwise ? 1.0 : -1.0
            let angle = direction * ((t.truncatingRemainder(dividingBy: duration) / duration) * 360) + phase
            ZStack {
                Circle().trim(from: 0, to: 0.48).stroke(AngularGradient(stops: [.init(color:.clear,location:0),.init(color:tint.opacity(0.07),location:0.18),.init(color:tint.opacity(0.30),location:0.48),.init(color:tint.opacity(0.80),location:0.78),.init(color:.white,location:1)],center:.center),style:StrokeStyle(lineWidth:9,lineCap:.round)).shadow(color:tint.opacity(0.75),radius:9).rotationEffect(.degrees(angle))
                Circle().fill(.white).frame(width:11,height:11).shadow(color:tint,radius:12).offset(y:-diameter/2).rotationEffect(.degrees(angle+172.8))
            }.frame(width:diameter,height:diameter)
        }
    }

    private var currentMission: some View {
        let task=activeTask; let done=task?.plan.steps.filter{$0.status == .completed}.count ?? 0; let total=task?.plan.steps.count ?? 0; let progress=total > 0 ? Double(done)/Double(total):0
        return hudPanel("MISSION CONTROL","scope") {
            Text(task?.title ?? "Awaiting mission").font(.system(size:14,weight:.semibold,design:.rounded)).lineLimit(1)
            Text(task?.plan.summary.isEmpty == false ? task!.plan.summary : appState.lastResponseSummary).font(.system(size:9,weight:.regular,design:.rounded)).foregroundStyle(.secondary).lineLimit(2)
            HStack { ProgressView(value:progress).tint(cyan); Text("\(Int(progress*100))%").font(.system(size:11,weight:.bold,design:.rounded)).foregroundStyle(.white) }
            HStack { data("STATUS",task?.status.rawValue.uppercased() ?? "READY",task?.status == .failed ? .red:.green); data("STEPS","\(done)/\(total)",cyan) }
        }
    }

    private var taskPipeline: some View { hudPanel("MISSION FLOW","arrow.triangle.branch") { HStack(spacing:2){flow("RECEIVE",true);connector;flow("PLAN",appState.isProcessing);connector;flow("EXECUTE",appState.isBusy);connector;flow("VERIFY",appState.isBusy);connector;flow("DONE",!appState.isBusy,.green)} } }
    private var missionActivity: some View { let events=appState.taskRuntime.tasks.flatMap(\.events).sorted{$0.createdAt>$1.createdAt}.prefix(6); return hudPanel("LIVE ACTIVITY","list.bullet.rectangle") { if events.isEmpty { Text("No activity yet").font(.caption).foregroundStyle(.secondary) } else { ForEach(Array(events),id:\.id){e in HStack(spacing:8){Circle().fill(e.type == .failed ? Color.red:cyan).frame(width:6,height:6).shadow(color:e.type == .failed ? .red:cyan,radius:4);Text(e.type.rawValue.uppercased()).font(.system(size:8,weight:.semibold,design:.rounded)).foregroundStyle(e.type == .failed ? .red:cyan).frame(width:78,alignment:.leading);Text(e.message).font(.system(size:9,weight:.regular,design:.rounded)).foregroundStyle(.secondary).lineLimit(1);Spacer()}} } } }
    private var quickActions: some View { hudPanel("QUICK ACTIONS","bolt.circle") { HStack(spacing:7){compact("NEW TASK","plus.circle"){showingChat=true;appState.chatInput="/plan "};compact("PROJECT","folder.badge.plus"){showingChat=true;appState.chatInput="Φτιάξε project "};compact("VOICE","mic"){appState.toggleListening()}} } }
    private var taskFlowBottom: some View { hudPanel("TASK FLOW","point.3.filled.connected.trianglepath.dotted") { HStack(spacing:3){flow("RECEIVED",true);connector;flow("PLAN",appState.isProcessing);connector;flow("RUN",appState.isBusy);connector;flow("VERIFY",appState.isBusy);connector;flow("DONE",!appState.isBusy,.green)} }.frame(maxWidth:.infinity) }
    private var learningPanel: some View { hudPanel("TRAVIS LEARNING","brain.fill") { data("AI REQUESTS","\(learning.totalAIRequests)",cyan);data("SUCCESS",String(format:"%.0f%%",learning.successRate*100),.green);data("LEARNED ROUTES","\(learning.learnedRoutes)",.purple);data("TOKENS","\(learning.totalTokens)",cyan);data("EST. COST",String(format:"$%.4f",learning.estimatedSpendUSD),.orange);Text(learning.bestKnownRoute).font(.system(size:8,weight:.medium,design:.rounded)).foregroundStyle(.secondary).lineLimit(1);HStack{Text("CONFIDENCE").font(.system(size:8,weight:.medium,design:.rounded));ProgressView(value:learning.confidence).tint(cyan);Text("\(Int(learning.confidence*100))%").font(.system(size:9,weight:.bold,design:.rounded)).foregroundStyle(cyan)} }.frame(width:335) }
    private var systemWave: some View { hudPanel("SYSTEM SIGNAL","waveform") { signalWave.frame(height:86);HStack{data("CPU","\(Int(telemetry.cpuPercent))%",cyan);data("RAM","\(Int(telemetry.memoryPercent))%",.purple);data("DISK","\(Int(telemetry.diskPercent))%",.orange)} }.frame(width:395) }
    private var signalWave: some View { TimelineView(.animation(minimumInterval:0.12)){timeline in Canvas{context,size in let t=timeline.date.timeIntervalSinceReferenceDate;var p=Path();let mid=size.height/2;for x in stride(from:0.0,through:size.width,by:3.0){let n=x/max(size.width,1);let y=mid+sin(n*18+t*2.4)*10+sin(n*47+t*1.3)*4;if x==0{p.move(to:CGPoint(x:x,y:y))}else{p.addLine(to:CGPoint(x:x,y:y))}};context.stroke(p,with:.color(cyan.opacity(0.12)),lineWidth:8);context.stroke(p,with:.color(cyan),lineWidth:2.2)}} }
    private var coreGrid: some View { Canvas{context,size in let c=CGPoint(x:size.width/2,y:size.height/2);for r in stride(from:CGFloat(60),through:255,by:26){context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:r*2,height:r*2)),with:.color(cyan.opacity(0.07)),lineWidth:0.8)};for a in stride(from:0.0,to:360.0,by:15.0){let rad=a * .pi/180;var p=Path();p.move(to:c);p.addLine(to:CGPoint(x:c.x+cos(rad)*255,y:c.y+sin(rad)*255));context.stroke(p,with:.color(cyan.opacity(0.025)),lineWidth:0.7)}} }

    private var premiumBackground: some View {
        ZStack {
            Color(red:0.0005, green:0.004, blue:0.025)
            LinearGradient(colors:[Color(red:0.001,green:0.012,blue:0.060),Color(red:0.002,green:0.030,blue:0.120),Color(red:0.001,green:0.016,blue:0.075),Color(red:0.0005,green:0.006,blue:0.035)],startPoint:.topLeading,endPoint:.bottomTrailing).opacity(0.98)
            RadialGradient(colors:[electric.opacity(0.13),.clear],center:.center,startRadius:40,endRadius:820)
            RadialGradient(colors:[cyan.opacity(0.060),.clear],center:UnitPoint(x:0.16,y:0.20),startRadius:0,endRadius:300)
            RadialGradient(colors:[electric.opacity(0.085),.clear],center:UnitPoint(x:0.86,y:0.74),startRadius:0,endRadius:360)
            Canvas{context,size in let grid:CGFloat=32;var p=Path();stride(from:CGFloat.zero,through:size.width,by:grid).forEach{x in p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height))};stride(from:CGFloat.zero,through:size.height,by:grid).forEach{y in p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y))};context.stroke(p,with:.color(cyan.opacity(0.024)),lineWidth:0.5)}
            RadialGradient(colors:[cyan.opacity(0.035),.clear],center:.center,startRadius:20,endRadius:720)
        }.ignoresSafeArea()
    }

    private var activeTask:AgentTask? { appState.taskRuntime.tasks.first{[.running,.planning,.waitingForApproval,.waitingForDependency].contains($0.status)} ?? appState.taskRuntime.tasks.first }
    private var coreState:String { appState.isProcessing ? "PROCESSING":appState.isBusy ? "EXECUTING":"ONLINE" }

    private func hudPanel<Content:View>(_ title:String,_ icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:10){
            HStack(spacing:7){Image(systemName:icon).font(.system(size:10,weight:.semibold));Text(title).font(.system(size:10,weight:.bold,design:.rounded)).tracking(0.7);Spacer();Rectangle().fill(LinearGradient(colors:[.clear,cyan.opacity(0.72)],startPoint:.leading,endPoint:.trailing)).frame(width:48,height:1.2)}.foregroundStyle(cyan)
            content()
        }
        .padding(12)
        .background(PremiumPanelShape(cut:13).fill(Color.black.opacity(0.82)).offset(y:7))
        .background(PremiumPanelShape(cut:13).fill(LinearGradient(stops:[.init(color:.white.opacity(0.070),location:0),.init(color:panel.opacity(0.96),location:0.12),.init(color:navy.opacity(0.995),location:1)],startPoint:.topLeading,endPoint:.bottomTrailing)))
        .overlay(PremiumPanelShape(cut:13).stroke(LinearGradient(colors:[.white.opacity(0.36),cyan.opacity(0.80),electric.opacity(0.20),navy.opacity(0.75)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1.7))
        .overlay(PremiumPanelShape(cut:13).stroke(.white.opacity(0.10),lineWidth:0.55).padding(3))
        .overlay(alignment:.topLeading){Rectangle().fill(LinearGradient(colors:[.white.opacity(0.98),cyan,.clear],startPoint:.leading,endPoint:.trailing)).frame(width:92,height:1.8).offset(x:15).shadow(color:cyan,radius:5)}
        .overlay(alignment:.top){LinearGradient(colors:[.white.opacity(0.18),cyan.opacity(0.05),.clear],startPoint:.leading,endPoint:.trailing).frame(height:18).clipShape(PremiumPanelShape(cut:13)).allowsHitTesting(false)}
        .overlay(alignment:.bottom){LinearGradient(colors:[.clear,navy.opacity(0.20),Color.black.opacity(0.72)],startPoint:.top,endPoint:.bottom).frame(height:30).clipShape(PremiumPanelShape(cut:13)).allowsHitTesting(false)}
        .overlay(alignment:.bottom){LinearGradient(colors:[.clear,electric.opacity(0.22),cyan.opacity(0.10),.clear],startPoint:.leading,endPoint:.trailing).frame(height:2).offset(y:3)}
        .shadow(color:.black.opacity(0.99),radius:18,y:13)
        .shadow(color:cyan.opacity(0.11),radius:12,y:-2)
    }

    private func modulePedestal(_ title:String,_ icon:String,_ status:String,_ tint:Color)->some View {
        VStack(spacing:0){
            ZStack {
                Ellipse().fill(Color.black.opacity(0.92)).frame(width:108,height:26).blur(radius:9).offset(y:59)
                Ellipse().fill(tint.opacity(0.16)).frame(width:94,height:17).blur(radius:8).offset(y:57)
                VStack(spacing:7){
                    ZStack{
                        PremiumHex().fill(LinearGradient(colors:[.white.opacity(0.16),tint.opacity(0.20),navy.opacity(0.94)],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:48,height:44)
                        PremiumHex().stroke(LinearGradient(colors:[.white.opacity(0.90),tint,navy.opacity(0.72)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1.8).frame(width:48,height:44).shadow(color:tint.opacity(0.85),radius:9)
                        Image(systemName:icon).font(.system(size:17,weight:.semibold)).foregroundStyle(tint).shadow(color:tint,radius:9)
                    }
                    Text(title).font(.system(size:10,weight:.semibold,design:.rounded)).foregroundStyle(.white.opacity(0.98))
                    Text(status).font(.system(size:7,weight:.bold,design:.rounded)).tracking(0.5).foregroundStyle(tint)
                }
                .frame(width:96,height:112)
                .background(PedestalBodyShape().fill(Color.black.opacity(0.78)).offset(y:6))
                .background(PedestalBodyShape().fill(LinearGradient(stops:[.init(color:.white.opacity(0.10),location:0),.init(color:tint.opacity(0.14),location:0.16),.init(color:panel.opacity(0.90),location:0.42),.init(color:navy.opacity(0.995),location:1)],startPoint:.topLeading,endPoint:.bottomTrailing)))
                .overlay(PedestalBodyShape().stroke(LinearGradient(colors:[.white.opacity(0.48),tint.opacity(0.88),navy],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1.7))
                .overlay(PedestalBodyShape().stroke(.white.opacity(0.08), lineWidth: 0.55).padding(3))
                .overlay(alignment:.top){LinearGradient(colors:[.white.opacity(0.22),.clear],startPoint:.top,endPoint:.bottom).frame(height:18).clipShape(PedestalBodyShape())}
                .shadow(color:.black.opacity(0.98),radius:12,y:11)
                .shadow(color:tint.opacity(0.26),radius:12,y:-4)
            }
            ZStack{
                Ellipse().fill(Color.black.opacity(0.96)).frame(width:108,height:24).blur(radius:6)
                Ellipse().fill(LinearGradient(colors:[.white.opacity(0.08),tint.opacity(0.14),navy.opacity(0.92)],startPoint:.top,endPoint:.bottom)).frame(width:98,height:19)
                Ellipse().stroke(tint.opacity(0.95),lineWidth:1.9).frame(width:84,height:13).shadow(color:tint,radius:10)
                Ellipse().stroke(.white.opacity(0.38),lineWidth:0.8).frame(width:64,height:7)
            }.offset(y:-2)
            ZStack {
                Ellipse().fill(tint.opacity(0.14)).frame(width:82,height:20).blur(radius:10)
                PedestalReflectionShape().fill(LinearGradient(colors:[tint.opacity(0.28),tint.opacity(0.09),.clear],startPoint:.top,endPoint:.bottom)).frame(width:74,height:38).blur(radius:1.5)
            }.offset(y:-5)
        }.frame(width:110,height:165)
    }

    private func rail(_ title:String,_ icon:String,action:@escaping()->Void)->some View { Button(action:action){HStack{Image(systemName:icon).frame(width:21).foregroundStyle(cyan);Text(title);Spacer();Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(cyan)}.font(.system(size:9,weight:.medium,design:.rounded)).padding(.vertical,6)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func compact(_ title:String,_ icon:String,action:@escaping()->Void)->some View { Button(action:action){HStack(spacing:4){Image(systemName:icon);Text(title)}.font(.system(size:8,weight:.semibold,design:.rounded)).frame(maxWidth:.infinity).padding(.vertical,6)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func iconButton(_ icon:String,action:@escaping()->Void)->some View { Button(action:action){Image(systemName:icon).frame(width:31,height:31).foregroundStyle(cyan)}.buttonStyle(PremiumButton(cyan:cyan)) }
    private func statusPill(_ text:String,_ color:Color)->some View { HStack(spacing:6){Circle().fill(color).frame(width:6,height:6).shadow(color:color,radius:5);Text(text)}.font(.system(size:8,weight:.semibold,design:.rounded)).foregroundStyle(color).padding(.horizontal,9).padding(.vertical,6).background(Capsule().fill(LinearGradient(colors:[.white.opacity(0.04),color.opacity(0.08),navy.opacity(0.55)],startPoint:.top,endPoint:.bottom))).overlay(Capsule().stroke(color.opacity(0.38),lineWidth:1)).shadow(color:.black.opacity(0.72),radius:5,y:4) }
    private func headerMetric(_ label:String,_ value:Double,_ tint:Color)->some View { VStack(alignment:.leading,spacing:2){Text(label).font(.system(size:7,weight:.medium,design:.rounded)).foregroundStyle(.secondary);Text("\(Int(value))%").font(.system(size:12,weight:.bold,design:.rounded)).foregroundStyle(.white);ProgressView(value:value,total:100).tint(tint)}.frame(width:72) }
    private func statusRow(_ name:String,_ value:String,_ tint:Color)->some View { HStack{Circle().stroke(cyan.opacity(0.45),lineWidth:1.2).frame(width:10,height:10);Text(name).font(.system(size:8,weight:.medium,design:.rounded));Spacer();Circle().fill(tint).frame(width:5,height:5).shadow(color:tint,radius:4);Text(value).font(.system(size:8,weight:.semibold,design:.rounded)).foregroundStyle(tint)}.padding(.vertical,4) }
    private func data(_ key:String,_ value:String,_ tint:Color)->some View { HStack{Text(key).font(.system(size:8,weight:.regular,design:.rounded)).foregroundStyle(.secondary);Spacer();Text(value).font(.system(size:9,weight:.semibold,design:.rounded)).foregroundStyle(tint)}.padding(.vertical,2) }
    private func module(_ title:String,_ icon:String,_ tint:Color)->some View { VStack(spacing:5){Image(systemName:icon).font(.system(size:18,weight:.semibold)).foregroundStyle(tint).shadow(color:tint.opacity(0.7),radius:5);Text(title).font(.system(size:7,weight:.semibold,design:.rounded));Text("ACTIVE").font(.system(size:6,weight:.bold,design:.rounded)).foregroundStyle(.green)}.frame(maxWidth:.infinity,minHeight:64).background(PremiumPanelShape(cut:7).fill(Color.black.opacity(0.72)).offset(y:4)).background(PremiumPanelShape(cut:7).fill(LinearGradient(colors:[.white.opacity(0.065),tint.opacity(0.07),panel.opacity(0.58),navy.opacity(0.92)],startPoint:.topLeading,endPoint:.bottomTrailing))).overlay(PremiumPanelShape(cut:7).stroke(LinearGradient(colors:[.white.opacity(0.30),tint.opacity(0.58),navy],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1.25)).overlay(PremiumPanelShape(cut:7).stroke(.white.opacity(0.06),lineWidth:0.5).padding(2)).shadow(color:.black.opacity(0.88),radius:7,y:6).shadow(color:tint.opacity(0.09),radius:5,y:-2) }
    private func gauge(_ value:Double,_ label:String,_ tint:Color)->some View { ZStack{Ellipse().fill(.black.opacity(0.80)).frame(width:64,height:15).blur(radius:6).offset(y:35);Circle().stroke(tint.opacity(0.12),lineWidth:8);Circle().trim(from:0,to:min(max(value/100,0),1)).stroke(tint,style:StrokeStyle(lineWidth:7,lineCap:.round)).rotationEffect(.degrees(-90)).shadow(color:tint.opacity(0.7),radius:5);Circle().stroke(.white.opacity(0.10),lineWidth:1).padding(5);VStack(spacing:1){Text(label).font(.system(size:7,weight:.medium,design:.rounded));Text("\(Int(value))%").font(.system(size:10,weight:.bold,design:.rounded))}.foregroundStyle(.white)}.frame(maxWidth:.infinity) }
    private func flow(_ title:String,_ active:Bool,_ tint:Color?=nil)->some View { let c=tint ?? cyan;return VStack(spacing:4){ZStack{Ellipse().fill(.black.opacity(0.68)).frame(width:36,height:9).blur(radius:4).offset(y:19);Circle().fill(RadialGradient(colors:[.white.opacity(active ? 0.10:0),c.opacity(active ? 0.14:0.025),navy.opacity(0.76)],center:.topLeading,startRadius:0,endRadius:22)).frame(width:40,height:40);Circle().stroke(c.opacity(active ? 0.72:0.16),lineWidth:1.6).frame(width:40,height:40).shadow(color:c.opacity(active ? 0.3:0),radius:4);Circle().fill(active ? c:.secondary).frame(width:6,height:6)};Text(title).font(.system(size:7,weight:.semibold,design:.rounded)).foregroundStyle(active ? .white:.secondary)}.frame(width:68) }
    private var connector:some View { HStack(spacing:0){Rectangle().fill(LinearGradient(colors:[cyan.opacity(0.12),cyan.opacity(0.58),cyan.opacity(0.12)],startPoint:.leading,endPoint:.trailing)).frame(height:1.5);Image(systemName:"chevron.right").font(.system(size:7,weight:.semibold)).foregroundStyle(cyan)}.frame(maxWidth:.infinity).shadow(color:cyan.opacity(0.2),radius:2) }
}

private struct PremiumPanelShape:Shape { let cut:CGFloat;func path(in r:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:cut,y:0));p.addLine(to:CGPoint(x:r.maxX-9,y:0));p.addLine(to:CGPoint(x:r.maxX,y:9));p.addLine(to:CGPoint(x:r.maxX,y:r.maxY-cut));p.addLine(to:CGPoint(x:r.maxX-cut,y:r.maxY));p.addLine(to:CGPoint(x:9,y:r.maxY));p.addLine(to:CGPoint(x:0,y:r.maxY-9));p.addLine(to:CGPoint(x:0,y:cut));p.closeSubpath();return p} }
private struct PremiumHex:Shape { func path(in r:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:r.width*0.22,y:0));p.addLine(to:CGPoint(x:r.width*0.78,y:0));p.addLine(to:CGPoint(x:r.width,y:r.height*0.5));p.addLine(to:CGPoint(x:r.width*0.78,y:r.height));p.addLine(to:CGPoint(x:r.width*0.22,y:r.height));p.addLine(to:CGPoint(x:0,y:r.height*0.5));p.closeSubpath();return p} }
private struct PedestalBodyShape:Shape { func path(in r:CGRect)->Path{var p=Path();p.move(to:CGPoint(x:10,y:0));p.addLine(to:CGPoint(x:r.maxX-10,y:0));p.addLine(to:CGPoint(x:r.maxX,y:10));p.addLine(to:CGPoint(x:r.maxX-4,y:r.maxY));p.addLine(to:CGPoint(x:4,y:r.maxY));p.addLine(to:CGPoint(x:0,y:10));p.closeSubpath();return p} }
private struct PedestalReflectionShape:Shape { func path(in r:CGRect)->Path { var p=Path();p.move(to:CGPoint(x:r.width*0.18,y:0));p.addLine(to:CGPoint(x:r.width*0.82,y:0));p.addLine(to:CGPoint(x:r.width*0.68,y:r.height));p.addLine(to:CGPoint(x:r.width*0.32,y:r.height));p.closeSubpath();return p } }
private struct CorePlatformShape: Shape { func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: 28, y: 0)); p.addLine(to: CGPoint(x: r.maxX - 28, y: 0)); p.addLine(to: CGPoint(x: r.maxX, y: 24)); p.addLine(to: CGPoint(x: r.maxX - 18, y: r.maxY)); p.addLine(to: CGPoint(x: 18, y: r.maxY)); p.addLine(to: CGPoint(x: 0, y: 24)); p.closeSubpath(); return p } }
private struct PremiumButton:ButtonStyle { let cyan:Color;func makeBody(configuration:Configuration)->some View{configuration.label.padding(.horizontal,7).background(PremiumPanelShape(cut:6).fill(Color.black.opacity(0.72)).offset(y:3)).background(PremiumPanelShape(cut:6).fill(LinearGradient(colors:[.white.opacity(configuration.isPressed ? 0.08:0.04),cyan.opacity(configuration.isPressed ? 0.14:0.04),Color(red:0.002,green:0.022,blue:0.082).opacity(0.94)],startPoint:.topLeading,endPoint:.bottomTrailing))).overlay(PremiumPanelShape(cut:6).stroke(LinearGradient(colors:[.white.opacity(0.22),cyan.opacity(configuration.isPressed ? 0.82:0.36),Color(red:0.002,green:0.015,blue:0.055)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1.15)).overlay(PremiumPanelShape(cut:6).stroke(.white.opacity(0.05),lineWidth:0.45).padding(2)).shadow(color:.black.opacity(0.88),radius:6,y:5).shadow(color:cyan.opacity(configuration.isPressed ? 0.20:0.04),radius:5,y:-1).scaleEffect(configuration.isPressed ? 0.985:1)} }
#endif
