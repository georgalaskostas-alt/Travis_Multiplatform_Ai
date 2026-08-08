import SwiftUI

@main
struct Travis_Multi_AIApp: App {
    @State private var appState = TRAVISAppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TRAVISRootView(appState: appState)
        }
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
