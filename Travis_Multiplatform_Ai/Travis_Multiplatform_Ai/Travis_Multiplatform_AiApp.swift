import SwiftUI

@main
struct Travis_Multi_AIApp: App {
    @State private var appState = TRAVISAppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TRAVISRootView(appState: appState)
        }
        #if os(macOS)
        .commands {
            CommandMenu("TRAVIS") {
                Button("Open FCC Assistant") {
                    NotificationCenter.default.post(name: .travisOpenFCCQuickAccess, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        #endif
        // Cold launch already starts on a fresh session via
        // TRAVISAppState.bootstrap(); `onChange` doesn't fire for that
        // initial value, only for actual transitions, so this covers
        // exactly "returned from background/inactivity" without double-
        // starting a session on launch.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appState.startNewSession()
            }
        }
    }
}

#if os(macOS)
extension Notification.Name {
    static let travisOpenFCCQuickAccess = Notification.Name("TRAVISOpenFCCQuickAccess")
}
#endif
