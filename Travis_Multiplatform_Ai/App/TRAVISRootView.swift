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
        #if os(iOS)
        .task { await synchronizeMacMissionState() }
        #endif
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()

            // Remote missions must enter the same durable autonomous execution
            // path as missions started directly on the Mac. The old /plan route
            // only created + started an AgentTask and left execution at 0% until
            // the user manually pressed RUN/AUTO in Mission Control.
            if lowered.hasPrefix("/plan ") {
                let goal = String(trimmed.dropFirst("/plan ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !goal.isEmpty else { return }
                appState.runAutonomousMissionV2(goal: goal)
                return
            }

            appState.chatInput = trimmed
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

    #if os(iOS)
    private func synchronizeMacMissionState() async {
        let bridge = TravisDeviceBridgeService.shared
        let activeStatusKeys: Set<String> = [
            "pending", "planning", "running", "waitingforapproval",
            "waitingfordependency", "paused"
        ]

        while !Task.isCancelled {
            if bridge.isConnected, let status = bridge.lastStatus {
                let activeTask = status.runtimeTasks
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first { snapshot in
                        activeStatusKeys.contains(normalizedStatus(snapshot.status))
                    }

                // While connected, the Mac runtime is authoritative for the
                // iPhone command-center mission state.
                appState.isBusy = activeTask != nil || status.isBusy
                appState.isProcessing = activeTask.map {
                    let key = normalizedStatus($0.status)
                    return key == "planning" || key == "running"
                } ?? status.isBusy

                if let activeTask {
                    let progress: String
                    if activeTask.totalSteps > 0 {
                        progress = "\(activeTask.completedSteps)/\(activeTask.totalSteps) steps"
                    } else {
                        progress = activeTask.status.uppercased()
                    }

                    let detail = activeTask.currentStep
                        ?? activeTask.checkpoint
                        ?? activeTask.goal
                    appState.lastResponseSummary = "\(activeTask.title) · \(progress) · \(detail)"
                } else if !status.lastSummary.isEmpty {
                    appState.lastResponseSummary = status.lastSummary
                }
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func normalizedStatus(_ status: String) -> String {
        status.lowercased().filter { $0.isLetter }
    }
    #endif

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
