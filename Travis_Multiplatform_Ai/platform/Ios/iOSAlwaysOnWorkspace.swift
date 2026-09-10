#if os(iOS)
import SwiftUI

struct iOSAlwaysOnWorkspace:View{
    @State private var bridge=TravisDeviceBridgeService.shared
    @State private var confirm=false
    @State private var expanded:Set<UUID>=[]
    private let cyan=Color(red:0.04,green:0.82,blue:1),panel=Color(red:0.004,green:0.042,blue:0.125)
    var body:some View{ZStack{Color.black.ignoresSafeArea();ScrollView{VStack(spacing:12){header;stats;controls;jobs}.padding(14)}}.navigationTitle("Always-On").task{while !Task.isCancelled{if bridge.isConnected{bridge.requestStatus()};try? await Task.sleep(for:.seconds(2))}}.alert("Emergency stop?",isPresented:$confirm){Button("STOP ALL",role:.destructive){bridge.sendCommandToMac("/alwayson-kill")};Button("Cancel",role:.cancel){}}}
    private var r:TravisBridgeAlwaysOnSnapshot?{bridge.lastStatus?.alwaysOn}
    private var header:some View{HStack{Image(systemName:"server.rack").foregroundStyle(cyan);VStack(alignment:.leading,spacing:3){Text("ALWAYS-ON RUNTIME").bold();Text(r?.summary ?? "WAITING FOR MAC").font(.caption).foregroundStyle(r?.workerHealthy == true ? .green:.orange);HStack(spacing:8){if let pid=r?.workerPID{Text("PID \(pid)")};if let age=r?.heartbeatAgeSeconds{Text(String(format:"HB %.1fs",age))};if let gen=r?.workerGeneration{Text("GEN \(gen.prefix(8))")}}.font(.caption2).foregroundStyle(.secondary)};Spacer();Circle().fill(r?.workerHealthy == true ? Color.green:Color.orange).frame(width:8,height:8)}.padding().background(RoundedRectangle(cornerRadius:14).fill(panel))}
    private var stats:some View{HStack{tile("WORKER",r?.workerHealthy == true ? "ONLINE":"OFFLINE",r?.workerHealthy == true ? .green:.red);tile("ACTIVE","\(r?.jobsActive ?? 0)",cyan);tile("FAILED","\(r?.jobsFailed ?? 0)",.orange)}}
    private var controls:some View{HStack{Button{confirm=true}label:{Label("KILL SWITCH",systemImage:"exclamationmark.octagon.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).tint(.red);Button{bridge.sendCommandToMac("/alwayson-clear-kill")}label:{Text("CLEAR").frame(maxWidth:.infinity)}.buttonStyle(.bordered).tint(cyan)}}
    @ViewBuilder private var jobs:some View{
        if let items=r?.jobs,!items.isEmpty{
            ForEach(items){j in
                VStack(alignment:.leading,spacing:10){
                    HStack{VStack(alignment:.leading,spacing:3){Text(j.title).bold();Text("\(j.kind.uppercased()) · \(j.state.uppercased())").font(.caption2).foregroundStyle(statusColor(j.state))};Spacer();Text("\(j.progressPercent)%").font(.caption.bold()).foregroundStyle(cyan)}
                    if let total=j.totalSteps,total>0{ProgressView(value:Double(j.completedSteps ?? 0),total:Double(total)).tint(cyan);Text("\(j.completedSteps ?? 0)/\(total) STEPS").font(.caption2).foregroundStyle(.secondary)}
                    marketPanel(j);portfolioPanel(j);auditPanel(j)
                    if let checkpoint=j.checkpoint,!checkpoint.isEmpty{Label(checkpoint,systemImage:"scope").font(.caption2).foregroundStyle(.secondary)}
                    if (j.recoveryCount ?? 0)>0{Label("RECOVERED \(j.recoveryCount ?? 0)x",systemImage:"arrow.clockwise.circle.fill").font(.caption2).foregroundStyle(.orange)}
                    if let e=j.lastError{Text(e).font(.caption2).foregroundStyle(.orange)}
                    if let summary=j.lastSummary,!summary.isEmpty{Text(summary).font(.caption).foregroundStyle(.secondary)}
                    if let completed=j.lastCompletedAt{Text("LAST COMPLETED · \(completed.formatted(date:.abbreviated,time:.standard))").font(.caption2).foregroundStyle(.secondary)}
                    if let report=j.finalReport,!report.isEmpty{Button{if expanded.contains(j.id){expanded.remove(j.id)}else{expanded.insert(j.id)}}label:{Label(expanded.contains(j.id) ? "HIDE FINAL REPORT":"SHOW FINAL REPORT",systemImage:"doc.text.magnifyingglass").font(.caption.bold())}.buttonStyle(.plain).foregroundStyle(cyan);if expanded.contains(j.id){Text(report).font(.caption).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.28)))}}
                    HStack{if ["running","sleeping","scheduled"].contains(j.state.lowercased()){Button("PAUSE"){bridge.sendCommandToMac("/alwayson-pause \(j.id)")}};if j.state.lowercased()=="paused"{Button("RESUME"){bridge.sendCommandToMac("/alwayson-resume \(j.id)")}};if j.state.lowercased()=="failed"{Button("RETRY"){bridge.sendCommandToMac("/alwayson-retry \(j.id)")}.tint(.orange)};Button("DELETE",role:.destructive){bridge.sendCommandToMac("/alwayson-delete \(j.id)")}}.buttonStyle(.bordered)
                }.padding().background(RoundedRectangle(cornerRadius:12).fill(panel))
            }
        }else{Text("No persistent jobs yet.").foregroundStyle(.secondary).padding(30)}
    }
    @ViewBuilder private func marketPanel(_ j:TravisBridgeAlwaysOnJobSnapshot)->some View{
        if let asset=j.marketLeader{
            VStack(alignment:.leading,spacing:7){HStack{Label("MARKET INTELLIGENCE",systemImage:"waveform.path.ecg").font(.caption2.bold()).foregroundStyle(cyan);Spacer();if let signal=j.marketLeaderSignal{Text(signal.uppercased()).font(.caption2.bold()).foregroundStyle(signalColor(signal))}};HStack{metric(asset,"LEADER");metric(j.marketLeaderScore.map{String(format:"%.2f",$0)} ?? "—","SCORE");metric(j.marketLeaderConfidence.map{"\(Int($0*100))%"} ?? "—","CONF")};HStack{Text("RSI \(j.marketLeaderRSI.map{String(format:"%.1f",$0)} ?? "—")");Spacer();Text("24H \(j.marketLeader24h.map{String(format:"%+.2f%%",$0)} ?? "—")");Spacer();Text((j.marketRegime ?? "—").uppercased())}.font(.caption2).foregroundStyle(.secondary)}.padding(10).background(RoundedRectangle(cornerRadius:10).fill(.black.opacity(0.27))).overlay(RoundedRectangle(cornerRadius:10).stroke(cyan.opacity(0.18),lineWidth:0.7))
        }
    }
    @ViewBuilder private func portfolioPanel(_ j:TravisBridgeAlwaysOnJobSnapshot)->some View{
        if let equity=j.portfolioEquity{
            VStack(alignment:.leading,spacing:7){HStack{Label("PAPER PORTFOLIO",systemImage:"chart.line.uptrend.xyaxis").font(.caption2.bold()).foregroundStyle(cyan);Spacer();Text(String(format:"%.2f USDT",equity)).font(.caption.bold())};HStack{metric(j.dailyPnL.map{String(format:"%+.2f",$0)} ?? "—","TODAY");metric(j.unrealizedPnL.map{String(format:"%+.2f",$0)} ?? "—","UNREAL");metric(j.winRate.map{"\(Int($0*100))%"} ?? "—","WIN RATE")};HStack{Text("OPEN \(j.openPositions ?? 0)");Spacer();Text("CLOSED \(j.closedTrades ?? 0)");Spacer();Text("PF \(j.profitFactor.map{String(format:"%.2f",$0)} ?? "—")");Spacer();Text("DD \(j.drawdownPercent.map{String(format:"%.2f%%",$0)} ?? "—")")}.font(.caption2).foregroundStyle(.secondary);if let action=j.recentTradeAction,!action.isEmpty{Label(action,systemImage:"bolt.horizontal.circle").font(.caption2).foregroundStyle(.secondary)}}.padding(10).background(RoundedRectangle(cornerRadius:10).fill(.black.opacity(0.27))).overlay(RoundedRectangle(cornerRadius:10).stroke(cyan.opacity(0.18),lineWidth:0.7))
        }
    }
    @ViewBuilder private func auditPanel(_ j:TravisBridgeAlwaysOnJobSnapshot)->some View{if j.auditHigh != nil || j.auditMedium != nil || j.auditLow != nil{HStack{Label("SELF AUDIT",systemImage:"shield.lefthalf.filled").font(.caption2.bold()).foregroundStyle(cyan);Spacer();Text("HIGH \(j.auditHigh ?? 0)").foregroundStyle(.red);Text("MED \(j.auditMedium ?? 0)").foregroundStyle(.orange);Text("LOW \(j.auditLow ?? 0)").foregroundStyle(.secondary)}.font(.caption2).padding(10).background(RoundedRectangle(cornerRadius:10).fill(.black.opacity(0.27)))}}
    private func metric(_ value:String,_ label:String)->some View{VStack(spacing:2){Text(value).font(.caption.bold()).lineLimit(1);Text(label).font(.system(size:7,weight:.bold)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity)}
    private func signalColor(_ signal:String)->Color{signal.lowercased().contains("bull") ? .green:signal.lowercased().contains("bear") ? .red:.secondary}
    private func statusColor(_ state:String)->Color{switch state.lowercased(){case "running","sleeping","scheduled":return .green;case "failed":return .orange;case "paused":return .yellow;default:return .secondary}}
    private func tile(_ a:String,_ b:String,_ c:Color)->some View{VStack{Text(a).font(.caption2);Text(b).font(.caption.bold()).foregroundStyle(c)}.frame(maxWidth:.infinity).padding().background(RoundedRectangle(cornerRadius:10).fill(panel))}
}
#endif
