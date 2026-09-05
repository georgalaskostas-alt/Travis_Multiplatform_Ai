#if os(iOS)
import SwiftUI

struct iOSAlwaysOnWorkspace:View{
    @State private var bridge=TravisDeviceBridgeService.shared
    @State private var confirm=false
    @State private var expanded:Set<UUID>=[]
    private let cyan=Color(red:0.04,green:0.82,blue:1),panel=Color(red:0.004,green:0.042,blue:0.125)

    var body:some View{
        ZStack{Color.black.ignoresSafeArea();ScrollView{VStack(spacing:12){header;stats;controls;jobs}.padding(14)}}
            .navigationTitle("Always-On")
            .task{while !Task.isCancelled{if bridge.isConnected{bridge.requestStatus()};try? await Task.sleep(for:.seconds(2))}}
            .alert("Emergency stop?",isPresented:$confirm){Button("STOP ALL",role:.destructive){bridge.sendCommandToMac("/alwayson-kill")};Button("Cancel",role:.cancel){}}
    }

    private var r:TravisBridgeAlwaysOnSnapshot?{bridge.lastStatus?.alwaysOn}
    private var header:some View{HStack{Image(systemName:"server.rack").foregroundStyle(cyan);VStack(alignment:.leading,spacing:3){Text("ALWAYS-ON RUNTIME").bold();Text(r?.summary ?? "WAITING FOR MAC").font(.caption).foregroundStyle(r?.workerHealthy == true ? .green:.orange);if let pid=r?.workerPID{Text("WORKER PID \(pid)").font(.caption2).foregroundStyle(.secondary)}};Spacer()}.padding().background(RoundedRectangle(cornerRadius:14).fill(panel))}
    private var stats:some View{HStack{tile("WORKER",r?.workerHealthy == true ? "ONLINE":"OFFLINE",r?.workerHealthy == true ? .green:.red);tile("ACTIVE","\(r?.jobsActive ?? 0)",cyan);tile("FAILED","\(r?.jobsFailed ?? 0)",.orange)}}
    private var controls:some View{HStack{Button{confirm=true}label:{Label("KILL SWITCH",systemImage:"exclamationmark.octagon.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).tint(.red);Button{bridge.sendCommandToMac("/alwayson-clear-kill")}label:{Text("CLEAR").frame(maxWidth:.infinity)}.buttonStyle(.bordered).tint(cyan)}}

    @ViewBuilder private var jobs:some View{
        if let items=r?.jobs,!items.isEmpty{
            ForEach(items){j in
                VStack(alignment:.leading,spacing:10){
                    HStack{VStack(alignment:.leading,spacing:3){Text(j.title).bold();Text("\(j.kind.uppercased()) · \(j.state.uppercased())").font(.caption2).foregroundStyle(statusColor(j.state))};Spacer();Text("\(j.progressPercent)%").font(.caption.bold()).foregroundStyle(cyan)}
                    if let total=j.totalSteps,total>0{ProgressView(value:Double(j.completedSteps ?? 0),total:Double(total)).tint(cyan);Text("\(j.completedSteps ?? 0)/\(total) STEPS").font(.caption2).foregroundStyle(.secondary)}
                    if let checkpoint=j.checkpoint,!checkpoint.isEmpty{Label(checkpoint,systemImage:"scope").font(.caption2).foregroundStyle(.secondary)}
                    if (j.recoveryCount ?? 0)>0{Label("RECOVERED \(j.recoveryCount ?? 0)x",systemImage:"arrow.clockwise.circle.fill").font(.caption2).foregroundStyle(.orange)}
                    if let e=j.lastError{Text(e).font(.caption2).foregroundStyle(.orange)}
                    if let summary=j.lastSummary,!summary.isEmpty{Text(summary).font(.caption).foregroundStyle(.secondary)}
                    if let report=j.finalReport,!report.isEmpty{
                        Button{if expanded.contains(j.id){expanded.remove(j.id)}else{expanded.insert(j.id)}}label:{Label(expanded.contains(j.id) ? "HIDE FINAL REPORT":"SHOW FINAL REPORT",systemImage:"doc.text.magnifyingglass").font(.caption.bold())}.buttonStyle(.plain).foregroundStyle(cyan)
                        if expanded.contains(j.id){Text(report).font(.caption).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(.black.opacity(0.28)))}
                    }
                    HStack{
                        if j.state.lowercased()=="running" || j.state.lowercased()=="sleeping" || j.state.lowercased()=="scheduled"{Button("PAUSE"){bridge.sendCommandToMac("/alwayson-pause \(j.id)")}}
                        if j.state.lowercased()=="paused"{Button("RESUME"){bridge.sendCommandToMac("/alwayson-resume \(j.id)")}}
                        if j.state.lowercased()=="failed"{Button("RETRY"){bridge.sendCommandToMac("/alwayson-retry \(j.id)")}.tint(.orange)}
                        Button("DELETE",role:.destructive){bridge.sendCommandToMac("/alwayson-delete \(j.id)")}
                    }.buttonStyle(.bordered)
                }.padding().background(RoundedRectangle(cornerRadius:12).fill(panel))
            }
        }else{Text("No persistent jobs yet.").foregroundStyle(.secondary).padding(30)}
    }

    private func statusColor(_ state:String)->Color{switch state.lowercased(){case "running","sleeping","scheduled":return .green;case "failed":return .orange;case "paused":return .yellow;default:return .secondary}}
    private func tile(_ a:String,_ b:String,_ c:Color)->some View{VStack{Text(a).font(.caption2);Text(b).font(.caption.bold()).foregroundStyle(c)}.frame(maxWidth:.infinity).padding().background(RoundedRectangle(cornerRadius:10).fill(panel))}
}
#endif
