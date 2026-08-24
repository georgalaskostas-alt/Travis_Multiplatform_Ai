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
        .onAppear {
            configureDeviceBridge()
        }
    }

    private func configureDeviceBridge() {
        let bridge = TravisDeviceBridgeService.shared

        bridge.statusProvider = { [weak appState] in
            guard let appState else {
                return TravisBridgeStatusSnapshot(
                    deviceName: "TRAVIS",
                    platform: platformName,
                    isBusy: false,
                    activeRuntimeTasks: 0,
                    lastSummary: "Unavailable",
                    fccAvailable: false
                )
            }

            let activeRuntimeTasks = appState.taskRuntime.tasks.filter {
                [.pending, .planning, .running, .waitingForApproval, .waitingForDependency, .paused].contains($0.status)
            }.count

            return TravisBridgeStatusSnapshot(
                deviceName: ProcessInfo.processInfo.hostName,
                platform: platformName,
                isBusy: appState.isBusy,
                activeRuntimeTasks: activeRuntimeTasks,
                lastSummary: appState.lastResponseSummary,
                fccAvailable: fccAvailableOnThisDevice
            )
        }

        bridge.onRemoteCommand = { [weak appState] text in
            guard let appState else { return }
            appState.chatInput = text
            appState.sendChat()
        }

        bridge.onSystemScan = { [weak appState] in
            appState?.runLocalSystemScan()
        }

        bridge.onSpeak = { [weak appState] text in
            guard let appState else { return }
            SpeechService.shared.speak(text, language: appState.preferredLanguage)
        }

        #if os(macOS)
        bridge.onOpenFCC = {
            NotificationCenter.default.post(name: .travisOpenFCCQuickAccess, object: nil)
        }
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
