import SwiftUI

@main
struct Travis_Multi_AIApp: App {
    @State private var appState = TRAVISAppState()

    var body: some Scene {
        WindowGroup {
            TRAVISRootView(appState: appState)
        }
    }
}
