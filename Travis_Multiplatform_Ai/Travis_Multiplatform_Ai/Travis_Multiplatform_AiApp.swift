import SwiftUI

@main
struct Travis_Multi_AIApp: App {
    @State private var appState = TRAVISAppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var didPlayColdLaunchSound = false
    @AppStorage("voice.startupGreeting") private var startupGreeting = "Καλώς ήρθες. TRAVIS online."

    var body: some Scene {
        WindowGroup {
            TRAVISRootView(appState: appState)
                .onAppear {
                    #if os(macOS)
                    guard !didPlayColdLaunchSound else { return }
                    didPlayColdLaunchSound = true
                    PrivateAudioProfileService.shared.playStartupSequence(
                        greeting: startupGreeting,
                        language: appState.preferredLanguage
                    )
                    #endif
                }
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
