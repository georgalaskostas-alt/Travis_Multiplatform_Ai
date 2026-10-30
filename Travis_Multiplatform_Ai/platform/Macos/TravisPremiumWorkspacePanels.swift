#if os(macOS)
import SwiftUI

struct TravisPremiumTasksView: View {
    @Bindable var appState: TRAVISAppState
    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)

    var body: some View {
        VStack(spacing: 0) {
            header("AUTONOMOUS TASK CONTROL", "checklist", "\(appState.activeTasks.count) TASKS")
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(appState.activeTasks) { task in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9).fill(cyan.opacity(0.07)).frame(width: 42, height: 42)
                                RoundedRectangle(cornerRadius: 9).stroke(cyan.opacity(0.30), lineWidth: 1).frame(width: 42, height: 42)
                                Image(systemName: "bolt.fill").foregroundStyle(cyan)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.system(size: 11, weight: .bold, design: .rounded))
                                Text(task.details).font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(task.status.rawValue.uppercased()).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(statusColor(task.status.rawValue))
                                Text(task.priority.rawValue.uppercased()).font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(cardBackground)
                        .overlay(cardBorder)
                    }
                }.padding(16)
            }
        }.background(workspaceBackground)
    }

    private func statusColor(_ status: String) -> Color { status.lowercased().contains("fail") ? .red : status.lowercased().contains("run") ? .orange : .green }
    private func header(_ title:String,_ icon:String,_ value:String)->some View { HStack { Image(systemName:icon).foregroundStyle(cyan); Text(title).font(.system(size:12,weight:.heavy,design:.rounded)).tracking(1); Spacer(); Text(value).font(.system(size:8,weight:.bold,design:.rounded)).foregroundStyle(.secondary) }.padding(16).background(.white.opacity(0.025)) }
    private var cardBackground: some ShapeStyle { LinearGradient(colors:[.white.opacity(0.045),cyan.opacity(0.025),Color.black.opacity(0.30)],startPoint:.topLeading,endPoint:.bottomTrailing) }
    private var cardBorder: some View { RoundedRectangle(cornerRadius:12).stroke(cyan.opacity(0.22),lineWidth:1) }
    private var workspaceBackground: some View { LinearGradient(colors:[Color(red:0.002,green:0.014,blue:0.052),Color(red:0.002,green:0.027,blue:0.090),Color.black.opacity(0.96)],startPoint:.topLeading,endPoint:.bottomTrailing) }
}

struct TravisPremiumMemoryView: View {
    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    var body: some View {
        VStack(spacing:0) {
            HStack { Image(systemName:"memorychip.fill").foregroundStyle(cyan); Text("LEARNING & MEMORY CORE").font(.system(size:12,weight:.heavy,design:.rounded)).tracking(1); Spacer(); Text("LIVE").font(.system(size:8,weight:.bold,design:.rounded)).foregroundStyle(.green) }.padding(16).background(.white.opacity(0.025))
            ScrollView {
                Text(LocalIntelligenceMetrics.shared.diagnosticReport())
                    .font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.88)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(18)
                    .background(RoundedRectangle(cornerRadius:14).fill(.black.opacity(0.28))).overlay(RoundedRectangle(cornerRadius:14).stroke(cyan.opacity(0.22),lineWidth:1)).padding(16)
            }
        }.background(LinearGradient(colors:[Color(red:0.002,green:0.014,blue:0.052),Color(red:0.002,green:0.027,blue:0.090),Color.black.opacity(0.96)],startPoint:.topLeading,endPoint:.bottomTrailing))
    }
}

struct TravisPremiumFCCView: View {
    @Bindable var appState: TRAVISAppState
    @State private var status = "NOT CHECKED"
    @State private var response = "FCC output will appear here."
    @State private var loading = false
    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)

    var body: some View {
        VStack(spacing:0) {
            HStack {
                ZStack { RoundedRectangle(cornerRadius:9).fill(cyan.opacity(0.08)).frame(width:40,height:40); RoundedRectangle(cornerRadius:9).stroke(cyan.opacity(0.35),lineWidth:1).frame(width:40,height:40); Image(systemName:"waveform.path.ecg").foregroundStyle(cyan) }
                VStack(alignment:.leading,spacing:2) { Text("FCC SYSTEM").font(.system(size:13,weight:.heavy,design:.rounded)).tracking(1); Text("READ-ONLY PROCESS INTELLIGENCE • TRAVIS AI").font(.system(size:8,weight:.bold,design:.rounded)).foregroundStyle(cyan) }
                Spacer(); Circle().fill(status.contains("ONLINE") ? Color.green : Color.orange).frame(width:6,height:6); Text(status).font(.system(size:8,weight:.bold,design:.rounded)).foregroundStyle(.secondary)
            }.padding(16).background(.white.opacity(0.025))

            HStack(spacing:8) {
                action("CHECK FCC","antenna.radiowaves.left.and.right"){checkStatus()}
                action("DEMO SHIFT","waveform"){run("FCC demo shift")}
                action("ASK TRAVIS","brain.head.profile"){appState.chatInput="FCC: "}
                action("SHIFT REPORT","doc.text.magnifyingglass"){appState.chatInput="FCC shift report: "}
            }.padding(14)

            ScrollView {
                Text(response).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.88)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(16)
            }.background(RoundedRectangle(cornerRadius:14).fill(.black.opacity(0.30))).overlay(RoundedRectangle(cornerRadius:14).stroke(cyan.opacity(0.24),lineWidth:1)).padding(.horizontal,14).padding(.bottom,14)
            if loading { ProgressView().tint(cyan).padding(.bottom,10) }
        }.background(LinearGradient(colors:[Color(red:0.002,green:0.014,blue:0.052),Color(red:0.002,green:0.027,blue:0.090),Color.black.opacity(0.96)],startPoint:.topLeading,endPoint:.bottomTrailing))
    }

    private func action(_ title:String,_ icon:String,_ block:@escaping()->Void)->some View { Button(action:block){HStack(spacing:6){Image(systemName:icon);Text(title)}.font(.system(size:8,weight:.bold,design:.rounded)).foregroundStyle(cyan).frame(maxWidth:.infinity).padding(.vertical,8).background(RoundedRectangle(cornerRadius:8).fill(cyan.opacity(0.065))).overlay(RoundedRectangle(cornerRadius:8).stroke(cyan.opacity(0.32),lineWidth:1))}.buttonStyle(.plain) }
    private func run(_ command:String){appState.chatInput=command;appState.sendChat()}
    private func checkStatus(){loading=true;Task{@MainActor in do{guard let capability=appState.orchestrator.capabilities.first(where:{$0.id=="fcc_assistant"})else{status="MODULE MISSING";loading=false;return};let result=try await capability.handle(command:"FCC status",recentHistory:[]);switch result{case .reply(let text):response=text;status="FCC ONLINE";case .proposal:response="Unexpected FCC proposal.";status="CHECK FCC";case .none:response="No FCC response.";status="CHECK FCC"}}catch{response=error.localizedDescription;status="FCC OFFLINE"};loading=false}}
}
#endif
