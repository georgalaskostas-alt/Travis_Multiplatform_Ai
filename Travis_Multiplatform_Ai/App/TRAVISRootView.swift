import SwiftUI

struct TRAVISRootView: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        Group {
            #if os(macOS)
            MacAppShell(appState: appState)
            #else
            iOSAppShell(appState: appState)
            #endif
        }
        .onAppear { configureDeviceBridge() }
    }

    private func configureDeviceBridge() {
        let bridge = TravisDeviceBridgeService.shared

        bridge.statusProvider = { [weak appState] in
            guard let appState else {
                return TravisBridgeStatusSnapshot(deviceName: "TRAVIS", platform: platformName, isBusy: false, activeRuntimeTasks: 0, lastSummary: "Unavailable", fccAvailable: false)
            }

            let allTasks = appState.taskRuntime.tasks.sorted { $0.updatedAt > $1.updatedAt }
            let activeStatuses: Set<AgentTaskStatus> = [.pending, .planning, .running, .waitingForApproval, .waitingForDependency, .paused]
            let activeRuntimeTasks = allTasks.filter { activeStatuses.contains($0.status) }.count

            let snapshots = allTasks.prefix(30).map { task in
                let completed = task.plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
                let currentStep = task.executionState.currentStepId.flatMap { id in
                    task.plan.steps.first(where: { $0.id == id })?.title
                }
                return TravisBridgeTaskSnapshot(
                    id: task.id,
                    title: task.title,
                    goal: task.goal,
                    status: task.status.rawValue,
                    priority: task.priority.rawValue,
                    completedSteps: completed,
                    totalSteps: task.plan.steps.count,
                    currentStep: currentStep,
                    checkpoint: task.executionState.lastCheckpoint?.summary,
                    updatedAt: task.updatedAt
                )
            }

            return TravisBridgeStatusSnapshot(
                deviceName: ProcessInfo.processInfo.hostName,
                platform: platformName,
                isBusy: appState.isBusy,
                activeRuntimeTasks: activeRuntimeTasks,
                lastSummary: appState.lastResponseSummary,
                fccAvailable: fccAvailableOnThisDevice,
                runtimeTasks: snapshots
            )
        }

        bridge.onRemoteCommand = { [weak appState] text in
            guard let appState else { return }
            appState.chatInput = text
            appState.sendChat()
        }
        bridge.onSystemScan = { [weak appState] in appState?.runLocalSystemScan() }
        bridge.onSpeak = { [weak appState] text in
            guard let appState else { return }
            SpeechService.shared.speak(text, language: appState.preferredLanguage)
        }
        #if os(macOS)
        bridge.onOpenFCC = { NotificationCenter.default.post(name: .travisOpenFCCQuickAccess, object: nil) }
        #endif
        bridge.start()
    }

    private var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #else
        "Apple Platform"
        #endif
    }

    private var fccAvailableOnThisDevice: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
