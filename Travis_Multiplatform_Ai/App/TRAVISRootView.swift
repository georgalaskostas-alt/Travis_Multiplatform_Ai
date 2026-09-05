import SwiftUI
#if os(iOS)
import UserNotifications
import UIKit
#endif

struct TRAVISRootView: View {
    @Bindable var appState: TRAVISAppState
    @State private var observedMacTaskStatuses:[UUID:String]=[:]
    var body:some View { Group {
#if os(macOS)
        MacAppShell(appState:appState)
#else
        iOSAppShell(appState:appState)
#endif
    }.onAppear{configureRuntimeAndBridge()}
#if os(iOS)
    .task{await synchronizeMacMissionState()}
#endif
    }

    private func configureRuntimeAndBridge(){
        let bridge=TravisDeviceBridgeService.shared
#if os(macOS)
        AlwaysOnRuntimeCoordinator.shared.configure(appState:appState)
#endif
        bridge.statusProvider={ [weak appState] in
            guard let appState else{return TravisBridgeStatusSnapshot(deviceName:"TRAVIS",platform:platformName,isBusy:false,activeRuntimeTasks:0,lastSummary:"Unavailable",fccAvailable:false)}
            let all=appState.taskRuntime.tasks.sorted{$0.updatedAt>$1.updatedAt};let active:Set<AgentTaskStatus>=[.pending,.planning,.running,.waitingForApproval,.waitingForDependency,.paused]
            let snapshots=all.prefix(30).map{task in
                let completed=task.plan.steps.filter{$0.status == .completed || $0.status == .skipped}.count
                let current=task.executionState.currentStepId.flatMap{id in task.plan.steps.first{$0.id==id}?.title}
                let report=task.plan.steps.filter{$0.status == .completed}.sorted{$0.order<$1.order}.compactMap{s->String? in guard let r=s.resultSummary?.trimmingCharacters(in:.whitespacesAndNewlines),!r.isEmpty else{return nil};return "#\(s.order) \(s.title)\n\(r)"}.joined(separator:"\n\n")
                let steps=task.plan.steps.sorted{$0.order<$1.order}.map{s in TravisBridgeStepSnapshot(id:s.id,order:s.order,title:s.title,status:s.status.rawValue,capability:s.capabilityId,attemptCount:s.attemptCount,maxAttempts:s.maxAttempts,requiresApproval:s.requiresApproval,lastError:s.lastError)}
                return TravisBridgeTaskSnapshot(id:task.id,title:task.title,goal:task.goal,status:task.status.rawValue,priority:task.priority.rawValue,completedSteps:completed,totalSteps:task.plan.steps.count,currentStep:current,checkpoint:task.executionState.lastCheckpoint?.summary,finalReport:task.status == .completed && !report.isEmpty ? String(report.prefix(8000)):nil,failureReason:task.failureReason,steps:steps,updatedAt:task.updatedAt)
            }
            var alwaysOn:TravisBridgeAlwaysOnSnapshot?=nil
#if os(macOS)
            let coordinator=AlwaysOnRuntimeCoordinator.shared;coordinator.worker.refresh();let status=AlwaysOnRuntimeStatus.current(engine:coordinator.engine,monitor:coordinator.worker)
            let workerJobs=coordinator.worker.serviceJobs.map{j in TravisBridgeAlwaysOnJobSnapshot(id:j.id,title:j.title,kind:j.kind,state:j.state,nextRunAt:j.nextRunAt.map{Date(timeIntervalSince1970:$0)},consecutiveFailures:j.failures,lastError:j.lastError,isEnabled:j.enabled)}
            let fallbackJobs=coordinator.engine.jobs.map{j in TravisBridgeAlwaysOnJobSnapshot(id:j.id,title:j.title,kind:j.kind.rawValue,state:j.state.rawValue,nextRunAt:j.nextRunAt,consecutiveFailures:j.consecutiveFailures,lastError:j.lastError,isEnabled:j.isEnabled)}
            alwaysOn=TravisBridgeAlwaysOnSnapshot(workerHealthy:status.workerHealthy,workerPID:status.workerPID,killSwitchEnabled:status.killSwitchEnabled,jobsTotal:status.jobsTotal,jobsActive:status.jobsActive,jobsFailed:status.jobsFailed,summary:status.summary,jobs:workerJobs.isEmpty ? fallbackJobs : workerJobs)
#endif
            return TravisBridgeStatusSnapshot(deviceName:ProcessInfo.processInfo.hostName,platform:platformName,isBusy:appState.isBusy,activeRuntimeTasks:all.filter{active.contains($0.status)}.count,lastSummary:appState.lastResponseSummary,fccAvailable:fccAvailableOnThisDevice,runtimeTasks:snapshots,alwaysOn:alwaysOn)
        }
        bridge.onRemoteCommand={ [weak appState] text in guard let appState else{return};let t=text.trimmingCharacters(in:.whitespacesAndNewlines);let lower=t.lowercased()
#if os(macOS)
            if let response=AlwaysOnCommandRouter.handle(t){appState.lastResponseSummary=response;return}
#endif
            if appState.handleRemoteMissionControlCommand(t){return};if lower.hasPrefix("/plan "){let goal=String(t.dropFirst(6)).trimmingCharacters(in:.whitespacesAndNewlines);if !goal.isEmpty{appState.runAutonomousMissionV2(goal:goal)};return};appState.chatInput=t;appState.sendChat() }
        bridge.onSystemScan={ [weak appState] in appState?.runLocalSystemScan() };bridge.onSpeak={ [weak appState] text in guard let appState else{return};SpeechService.shared.speak(text,language:appState.preferredLanguage)}
#if os(macOS)
        bridge.onOpenFCC={NotificationCenter.default.post(name:.travisOpenFCCQuickAccess,object:nil)}
#endif
        bridge.start()
    }
#if os(iOS)
    private func synchronizeMacMissionState() async { let bridge=TravisDeviceBridgeService.shared;let active:Set<String>=["pending","planning","running","waitingforapproval","waitingfordependency","paused"];TRAVISInlineMissionNotifier.prepare();while !Task.isCancelled{if bridge.isConnected{bridge.requestStatus()};if bridge.isConnected,let status=bridge.lastStatus{let tasks=status.runtimeTasks.sorted{$0.updatedAt>$1.updatedAt};let a=tasks.first{active.contains(normalizedStatus($0.status))};appState.isBusy=a != nil || status.isBusy;appState.isProcessing=a.map{let k=normalizedStatus($0.status);return k=="planning" || k=="running"} ?? status.isBusy;if let a{let p=a.totalSteps>0 ? "\(a.completedSteps)/\(a.totalSteps) steps · \(Int(Double(a.completedSteps)/Double(max(a.totalSteps,1))*100))%":a.status.uppercased();appState.lastResponseSummary="\(a.title) · \(p) · \(a.currentStep ?? a.checkpoint ?? a.goal)"}else if !status.lastSummary.isEmpty{appState.lastResponseSummary=status.lastSummary};for task in tasks{let current=normalizedStatus(task.status),previous=observedMacTaskStatuses[task.id];if previous != nil && previous != current && (current=="completed" || current=="failed"){TRAVISInlineMissionNotifier.notify(task:task)};if current=="completed",let previous,previous != "completed",let report=task.finalReport,!report.isEmpty{appState.addAssistantMessage("MISSION COMPLETED\n\n\(task.title)\n\nFINAL REPORT\n\(report)")}else if current=="failed",let previous,previous != "failed"{appState.addAssistantMessage("MISSION NEEDS ATTENTION\n\n\(task.title)\n\n\(task.failureReason ?? task.checkpoint ?? "Mission failed.")")};observedMacTaskStatuses[task.id]=current};let ids=Set(tasks.map(\.id));observedMacTaskStatuses=observedMacTaskStatuses.filter{ids.contains($0.key)}};try? await Task.sleep(for:.seconds(1))}}
    private func normalizedStatus(_ s:String)->String{s.lowercased().filter{$0.isLetter}}
#endif
    private var platformName:String{
#if os(macOS)
        "macOS"
#elseif os(iOS)
        "iOS"
#else
        "Apple Platform"
#endif
    }
    private var fccAvailableOnThisDevice:Bool{
#if os(macOS)
        true
#else
        false
#endif
    }
}

#if os(iOS)
private enum TRAVISInlineMissionNotifier {
    static func prepare() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
    static func notify(task: TravisBridgeTaskSnapshot) {
        let failed = task.status.lowercased().contains("fail");let content = UNMutableNotificationContent();content.title = failed ? "TRAVIS Mission Needs Attention" : "TRAVIS Mission Ready";content.subtitle = task.title
        let detail = failed ? (task.failureReason ?? task.checkpoint ?? "Mission failed.") : (task.finalReport ?? task.checkpoint ?? "Mission completed.");content.body = String(detail.prefix(180));content.sound = .default
        let request = UNNotificationRequest(identifier: "travis-mission-\(task.id)-\(task.status)", content: content, trigger: nil);UNUserNotificationCenter.current().add(request)
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(failed ? .error : .success) }
    }
}
#endif
