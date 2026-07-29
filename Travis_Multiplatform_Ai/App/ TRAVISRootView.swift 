import SwiftUI

struct TRAVISRootView: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        #if os(macOS)
        MacAppShell(appState: appState)
        #else
        iOSAppShell(appState: appState)
        #endif
    }
}
