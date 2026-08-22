import SwiftUI

struct MacAppShell: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        TravisWorkspaceLayer(appState: appState) {
            TravisPremiumCommandCenterView(appState: appState)
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.performUIAction(.openWorkspace(.fcc))
                } label: {
                    Label("FCC", systemImage: "waveform.path.ecg")
                }
                .help("Open FCC Assistant workspace")
                .accessibilityLabel("Open FCC Assistant workspace")
            }
        }
        .onAppear {
            routeLegacySelection(appState.selectedSidebarItem)
        }
        .onChange(of: appState.selectedSidebarItem) { _, item in
            routeLegacySelection(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .travisOpenFCCQuickAccess)) { _ in
            appState.performUIAction(.openWorkspace(.fcc))
        }
    }

    /// Compatibility bridge for controls that still set the old SidebarItem.
    /// They now open the premium workspace instead of replacing the command center
    /// with the legacy NavigationSplitView/detail UI.
    private func routeLegacySelection(_ item: SidebarItem) {
        switch item {
        case .chat:
            break // Dashboard/command center is the base view; chat is opened explicitly by its controls.
        case .history:
            appState.performUIAction(.openWorkspace(.history))
            appState.selectedSidebarItem = .chat
        case .tasks:
            appState.performUIAction(.openWorkspace(.tasks))
            appState.selectedSidebarItem = .chat
        case .permissions:
            appState.performUIAction(.openWorkspace(.permissions))
            appState.selectedSidebarItem = .chat
        case .settings:
            appState.performUIAction(.openWorkspace(.settings))
            appState.selectedSidebarItem = .chat
        }
    }
}
