#if os(macOS)
import SwiftUI

struct TravisCommandCenterView: View {
    @Bindable var appState: TRAVISAppState
    @State private var telemetry = TravisSystemTelemetry()
    @State private var spin = false
    @State private var glow = false
    private let cyan = Color(red: 0.08, green: 0.78, blue: 1)
    private let deep = Color(red: 0.005, green: 0.025, blue: 0.075)

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 14) {
                    topBar
                    HStack(alignment: .top, spacing: 14) {
                        leftRail.frame(width: 205)
                        VStack(spacing: 14) {
                            HStack(alignment: .top, spacing: 14) {
                                aiCore.frame(width: 470, height: 475)
                                VStack(spacing: 14) { systemOverview; taskFlow; currentTask }.frame(width: 520)
                            }
                            liveMetrics
                            HStack(alignment: .top, spacing: 14) { runtimePanel; activityPanel; commandPanel.frame(width: 270) }
                        }
                    }
                }
                .padding(16)
                .frame(minWidth: max(1260, geo.size.width), minHeight: max(820, geo.size.height), alignment: .topLeading)
            }.background(hudBackground.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .onAppear { spin = true; glow = true; telemetry.start() }
        .onDisappear { telemetry.stop() }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            ZStack { RoundedRectangle(cornerRadius: 7).fill(cyan.opacity(0.1)).frame(width: 48, height: 48); Image(systemName: "triangle.inset.filled").font(.system(size: 29, weight: .black)).foregroundStyle(cyan).shadow(color: cyan, radius: 12) }
            VStack(alignment: .leading, spacing: 1) { Text("TRAVIS").font(.system(size: 27, weight: .black, design: .rounded)).tracking(2.5); Text("AUTONOMOUS INTELLIGENCE · COMMAND CENTER").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(cyan) }
            Rectangle().fill(cyan.opacity(0.35)).frame(width: 1, height: 36)
            Label("SYSTEM OPERATIONAL", systemImage: "circle.fill").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            Spacer()
            VStack(alignment: .trailing) { Text(Date.now, style: .time).font(.system(size: 18, weight: .bold, design: .monospaced)); Text("UPTIME  \(telemetry.uptime)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
            HUDIconButton(icon: "magnifyingglass") { appState.selectedSidebarItem = .history }
            HUDIconButton(icon: "gearshape.fill") { appState.selectedSidebarItem = .settings }
            HUDIconButton(icon: appState.isListening ? "mic.fill" : "mic") { appState.toggleListening() }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(HUDChromeShape().fill(Color(red: 0.01, green: 0.06, blue: 0.13).opacity(0.94))).overlay(HUDChromeShape().stroke(cyan.opacity(0.65), lineWidth: 1)).shadow(color: cyan.opacity(0.12), radius: 16)
    }

    private var leftRail: some View {
        VStack(spacing: 12) {
            HUDPanel(title: "NAVIGATION", icon: "circle.grid.cross") { nav("DASHBOARD", "square.grid.2x2.fill", .chat); nav("HISTORY", "clock.arrow.circlepath", .history); nav("TASKS", "checklist", .tasks); nav("PERMISSIONS", "lock.shield.fill", .permissions); nav("SETTINGS", "gearshape.fill", .settings) }
            HUDPanel(title: "QUICK COMMAND", icon: "bolt.fill") { command("NEW TASK", "plus.circle.fill", "/plan "); command("NEW PROJECT", "folder.badge.plus", "Φτιάξε project "); command("TASK STATUS", "waveform.path.ecg", "/task-status ") }
            HUDPanel(title: "VOICE LINK", icon: "waveform") { Button { appState.toggleListening() } label: { VStack(spacing: 10) { ZStack { Circle().stroke(cyan.opacity(0.18)).frame(width: 92, height: 92); Circle().stroke(cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3,6])).frame(width: 74, height: 74).rotationEffect(.degrees(spin ? 360 : 0)).animation(.linear(duration: 12).repeatForever(autoreverses: false), value: spin); Circle().fill(cyan.opacity(appState.isListening ? 0.18 : 0.07)).frame(width: 54, height: 54); Image(systemName: appState.isListening ? "waveform" : "mic.fill").font(.system(size: 25)).foregroundStyle(cyan).shadow(color: cyan, radius: 9) }; Text(appState.isListening ? "LISTENING" : "VOICE STANDBY").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(appState.isListening ? .green : cyan) }.frame(maxWidth: .infinity) }.buttonStyle(.plain) }
            Spacer(minLength: 0)
        }
    }

    private var aiCore: some View {
        HUDPanel(title: "TRAVIS AI CORE", icon: "atom") {
            ZStack {
                radialGrid
                ForEach(0..<7, id: \.self) { i in Circle().trim(from: i.isMultiple(of: 2) ? 0.04 : 0.18, to: i.isMultiple(of: 2) ? 0.82 : 0.94).stroke(i < 3 ? cyan.opacity(0.88) : cyan.opacity(0.28), style: StrokeStyle(lineWidth: i == 0 ? 2.5 : 1, lineCap: .round, dash: i.isMultiple(of: 3) ? [2,7] : [])).frame(width: CGFloat(390-i*42), height: CGFloat(390-i*42)).rotationEffect(.degrees(spin ? Double((i.isMultiple(of: 2) ? 1 : -1) * (110+i*21)) : 0)).animation(.linear(duration: Double(18+i*3)).repeatForever(autoreverses: false), value: spin) }
                ForEach(0..<12, id: \.self) { i in Capsule().fill(cyan.opacity(i.isMultiple(of: 3) ? 0.9 : 0.25)).frame(width: 2, height: i.isMultiple(of: 3) ? 18 : 9).offset(y: -196).rotationEffect(.degrees(Double(i)*30)) }
                Circle().fill(RadialGradient(colors: [cyan.opacity(0.28), deep.opacity(0.95)], center: .center, startRadius: 5, endRadius: 90)).frame(width: 174, height: 174).overlay(Circle().stroke(cyan, lineWidth: 1.5)).shadow(color: cyan.opacity(glow ? 0.85 : 0.35), radius: glow ? 28 : 12).animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: glow)
                VStack(spacing: 5) { Text("TRAVIS").font(.system(size: 30, weight: .black, design: .rounded)).tracking(2); Text(appState.isProcessing ? "PROCESSING" : appState.isBusy ? "EXECUTING" : "ONLINE").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(appState.isBusy ? .orange : .green); Image(systemName: "waveform").foregroundStyle(cyan) }
                VStack { Spacer(); HStack { coreTag("PLANNER", appState.isProcessing); Spacer(); coreTag("EXECUTOR", appState.isBusy); Spacer(); coreTag("VERIFIER", appState.isBusy) }.padding(.horizontal, 22) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var radialGrid: some View { Canvas { context, size in let c=CGPoint(x:size.width/2,y:size.height/2); for r in stride(from: CGFloat(70), through: 205, by: 34) { context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:r*2,height:r*2)), with:.color(cyan.opacity(0.055)), lineWidth:0.5) }; for a in stride(from:0.0,to:360.0,by:30.0) { let rad=a * .pi / 180; var p=Path(); p.move(to:c); p.addLine(to:CGPoint(x:c.x+cos(rad)*205,y:c.y+sin(rad)*205)); context.stroke(p,with:.color(cyan.opacity(0.045)),lineWidth:0.5) } } }

    private var systemOverview: some View { HUDPanel(title:"SYSTEM OVERVIEW",icon:"server.rack") { status("TRAVIS CORE","OPERATIONAL","cpu",.green); status("AI ROUTER",appState.isInternetEnabled ? "AVAILABLE":"OFFLINE","point.3.connected.trianglepath.dotted",appState.isInternetEnabled ? .green:.orange); status("LOCAL ENGINE","ACTIVE","desktopcomputer",.green); status("TASK RUNTIME",appState.isBusy ? "EXECUTING":"READY","gearshape.2.fill",appState.isBusy ? .orange:.green); status("VOICE LINK",appState.isListening ? "LISTENING":"STANDBY","mic.fill",appState.isListening ? .green:cyan) } }
    private var taskFlow: some View { HUDPanel(title:"AUTONOMOUS TASK FLOW",icon:"arrow.triangle.branch") { HStack(spacing:3) { flow("RECEIVE","tray.and.arrow.down.fill",true); connector; flow("PLAN","brain.head.profile",appState.isProcessing); connector; flow("EXECUTE","bolt.fill",appState.isBusy); connector; flow("VERIFY","checkmark.shield.fill",appState.isBusy); connector; flow("READY","checkmark.circle.fill",!appState.isBusy,.green) }.padding(.vertical,5) } }

    private var currentTask: some View {
        let task = appState.taskRuntime.tasks.first(where: { [.running,.planning,.waitingForApproval,.waitingForDependency].contains($0.status) }) ?? appState.taskRuntime.tasks.first
        let done=task?.plan.steps.filter{$0.status == .completed}.count ?? 0, total=task?.plan.steps.count ?? 0
        let progress=total > 0 ? Double(done)/Double(total) : (appState.isBusy ? 0.15:1)
        return HUDPanel(title:"CURRENT MISSION",icon:"scope") { HStack(spacing:16) { VStack(alignment:.leading,spacing:7) { Text(task?.title ?? "Awaiting mission").font(.system(size:14,weight:.bold)).lineLimit(1); Text((task?.plan.summary.isEmpty == false ? task?.plan.summary : nil) ?? appState.lastResponseSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2); HStack { Text(task?.status.rawValue.uppercased() ?? "READY"); Spacer(); Text("\(done)/\(total) STEPS") }.font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(cyan); ProgressView(value:progress).tint(cyan) }; ringGauge(progress*100,"PROGRESS",cyan).frame(width:82,height:82) } }
    }

    private var liveMetrics: some View { HStack(spacing:14) { telemetryCard("CPU",telemetry.cpuPercent,"PROCESSOR","cpu",cyan); telemetryCard("RAM",telemetry.memoryPercent,"MEMORY","memorychip",.purple); telemetryCard("DISK",telemetry.diskPercent,"STORAGE","internaldrive",.orange); telemetryCard("TASKS",min(Double(appState.taskRuntime.tasks.filter{$0.status == .running}.count)*20,100),"ACTIVE \(appState.taskRuntime.tasks.filter{$0.status == .running}.count)","checklist",.green) } }
    private var runtimePanel: some View { HUDPanel(title:"RUNTIME INTELLIGENCE",icon:"brain") { let t=appState.taskRuntime.tasks; dataRow("TOTAL MISSIONS","\(t.count)"); dataRow("COMPLETED","\(t.filter{$0.status == .completed}.count)"); dataRow("RUNNING","\(t.filter{$0.status == .running}.count)"); dataRow("WAITING APPROVAL","\(t.filter{$0.status == .waitingForApproval}.count)"); dataRow("FAILED","\(t.filter{$0.status == .failed}.count)") }.frame(maxWidth:.infinity) }
    private var activityPanel: some View { HUDPanel(title:"MISSION ACTIVITY",icon:"waveform.path.ecg") { let events=appState.taskRuntime.tasks.flatMap(\.events).sorted{$0.createdAt > $1.createdAt}.prefix(5); if events.isEmpty { Text("No runtime events yet.").font(.caption).foregroundStyle(.secondary) } else { ForEach(Array(events),id:\.id) { e in log(e.type.rawValue.uppercased(),e.message,e.type == .failed ? .red:cyan) } } }.frame(maxWidth:.infinity) }
    private var commandPanel: some View { HUDPanel(title:"COMMAND ACCESS",icon:"terminal.fill") { commandButton("OPEN CHAT","message.fill") { appState.selectedSidebarItem = .chat; appState.chatInput="" }; commandButton("NEW MISSION","plus.circle.fill") { appState.selectedSidebarItem = .chat; appState.chatInput="/plan " }; commandButton("TASKS","checklist") { appState.selectedSidebarItem = .tasks }; commandButton("SECURITY","lock.shield.fill") { appState.selectedSidebarItem = .permissions } } }

    private func telemetryCard(_ title:String,_ value:Double,_ subtitle:String,_ icon:String,_ tint:Color)->some View { HUDPanel(title:title,icon:icon) { HStack(spacing:12) { ringGauge(value,"%",tint).frame(width:70,height:70); VStack(alignment:.leading,spacing:4) { Text(String(format:"%.0f%%",value)).font(.system(size:23,weight:.black,design:.rounded)); Text(subtitle).font(.system(size:8,weight:.bold,design:.monospaced)).foregroundStyle(.secondary); miniBars(value,tint) }; Spacer() } }.frame(maxWidth:.infinity) }
    private func ringGauge(_ value:Double,_ label:String,_ tint:Color)->some View { ZStack { Circle().stroke(tint.opacity(0.12),lineWidth:6); Circle().trim(from:0,to:min(max(value/100,0),1)).stroke(tint,style:StrokeStyle(lineWidth:6,lineCap:.round)).rotationEffect(.degrees(-90)).shadow(color:tint.opacity(0.7),radius:4); Text(label).font(.system(size:8,weight:.bold,design:.monospaced)).foregroundStyle(tint) } }
    private func miniBars(_ value:Double,_ tint:Color)->some View { HStack(spacing:2) { ForEach(0..<10,id:\.self) { i in Capsule().fill(Double(i)<value/10 ? tint:tint.opacity(0.12)).frame(width:4,height:CGFloat(6+(i%4)*2)) } } }
    private func coreTag(_ title:String,_ active:Bool)->some View { Text(title).font(.system(size:8,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(active ? .green:cyan.opacity(0.7)).padding(.horizontal,8).padding(.vertical,4).background(Capsule().fill(cyan.opacity(0.06))).overlay(Capsule().stroke(cyan.opacity(0.25))) }
    private func nav(_ title:String,_ icon:String,_ target:SidebarItem)->some View { Button { appState.selectedSidebarItem=target } label:{ HStack { Image(systemName:icon).frame(width:22); Text(title); Spacer(); Image(systemName:"chevron.right").font(.caption2) }.font(.system(size:10,weight:.bold,design:.monospaced)).padding(9).background(target == appState.selectedSidebarItem ? cyan.opacity(0.14):.clear).overlay(RoundedRectangle(cornerRadius:4).stroke(target == appState.selectedSidebarItem ? cyan.opacity(0.55):.clear)) }.buttonStyle(.plain) }
    private func command(_ title:String,_ icon:String,_ text:String)->some View { commandButton(title,icon) { appState.selectedSidebarItem = .chat; appState.chatInput=text } }
    private func commandButton(_ title:String,_ icon:String,action:@escaping()->Void)->some View { Button(action:action) { HStack { Image(systemName:icon).foregroundStyle(cyan).frame(width:20); Text(title); Spacer(); Image(systemName:"arrow.up.right").font(.caption2).foregroundStyle(.secondary) }.font(.system(size:10,weight:.semibold,design:.monospaced)).padding(.vertical,5) }.buttonStyle(.plain) }
    private func status(_ name:String,_ value:String,_ icon:String,_ tint:Color)->some View { HStack { Image(systemName:icon).foregroundStyle(cyan).frame(width:20); Text(name).font(.system(size:9,weight:.bold,design:.monospaced)); Spacer(); Circle().fill(tint).frame(width:5,height:5).shadow(color:tint,radius:4); Text(value).font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(tint) }.padding(.vertical,4) }
    private func flow(_ title:String,_ icon:String,_ active:Bool,_ tint:Color?=nil)->some View { VStack(spacing:5) { ZStack { Circle().fill((tint ?? cyan).opacity(active ? 0.14:0.03)).frame(width:42,height:42); Circle().stroke((tint ?? cyan).opacity(active ? 0.75:0.15)).frame(width:42,height:42); Image(systemName:icon).foregroundStyle(active ? (tint ?? cyan):.secondary) }; Text(title).font(.system(size:7,weight:.bold,design:.monospaced)).foregroundStyle(active ? .primary:.secondary) }.frame(width:72) }
    private var connector:some View { HStack(spacing:2) { Rectangle().fill(cyan.opacity(0.2)).frame(height:1); Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(cyan.opacity(0.6)) }.frame(maxWidth:.infinity) }
    private func dataRow(_ key:String,_ value:String)->some View { HStack { Text(key).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary); Spacer(); Text(value).font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(cyan) }.padding(.vertical,3) }
    private func log(_ tag:String,_ text:String,_ tint:Color)->some View { HStack(alignment:.top,spacing:7) { Text("[\(tag)]").font(.system(size:8,weight:.bold,design:.monospaced)).foregroundStyle(tint).frame(width:74,alignment:.leading); Text(text).font(.system(size:9,design:.monospaced)).lineLimit(1); Spacer() }.padding(.vertical,2) }

    private var hudBackground:some View { ZStack { LinearGradient(colors:[deep,Color(red:0.005,green:0.075,blue:0.16),Color(red:0.008,green:0.03,blue:0.09)],startPoint:.topLeading,endPoint:.bottomTrailing); Canvas { context,size in let step:CGFloat=34; var p=Path(); stride(from:CGFloat.zero,through:size.width,by:step).forEach{x in p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height))}; stride(from:CGFloat.zero,through:size.height,by:step).forEach{y in p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y))}; context.stroke(p,with:.color(cyan.opacity(0.045)),lineWidth:0.5) }; RadialGradient(colors:[cyan.opacity(0.07),.clear],center:.center,startRadius:20,endRadius:600) } }
}

private struct HUDPanel<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String = "circle.fill", @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).tracking(1.15)
                Spacer()
                Rectangle().fill(Color.cyan.opacity(0.35)).frame(width: 26, height: 1)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(red: 0.18, green: 0.82, blue: 1))
            content
        }
        .padding(12)
        .background(HUDChromeShape().fill(Color(red: 0.008, green: 0.052, blue: 0.115).opacity(0.91)))
        .overlay(HUDChromeShape().stroke(Color(red: 0.08, green: 0.72, blue: 1).opacity(0.48), lineWidth: 0.8))
        .shadow(color: Color.cyan.opacity(0.075), radius: 10)
    }
}

private struct HUDChromeShape:Shape { func path(in rect:CGRect)->Path { let c:CGFloat=9,cut:CGFloat=15;var p=Path();p.move(to:CGPoint(x:cut,y:0));p.addLine(to:CGPoint(x:rect.maxX-c,y:0));p.addQuadCurve(to:CGPoint(x:rect.maxX,y:c),control:CGPoint(x:rect.maxX,y:0));p.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY-cut));p.addLine(to:CGPoint(x:rect.maxX-cut,y:rect.maxY));p.addLine(to:CGPoint(x:c,y:rect.maxY));p.addQuadCurve(to:CGPoint(x:0,y:rect.maxY-c),control:CGPoint(x:0,y:rect.maxY));p.addLine(to:CGPoint(x:0,y:cut));p.closeSubpath();return p } }
private struct HUDIconButton:View { let icon:String;let action:()->Void;var body:some View { Button(action:action){Image(systemName:icon).frame(width:30,height:30).foregroundStyle(.cyan)}.buttonStyle(.plain).background(HUDChromeShape().fill(Color.cyan.opacity(0.06))).overlay(HUDChromeShape().stroke(Color.cyan.opacity(0.35))) } }
#endif
