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

    /// Compatibility bridge for any control that still changes SidebarItem.
    /// Route directly into the premium workspace layer and immediately restore
    /// the command center as the base screen. This avoids reopening legacy UI.
    private func routeLegacySelection(_ item: SidebarItem) {
        let action: TravisUIAction?
        switch item {
        case .chat:
            action = nil
        case .history:
            action = .openWorkspace(.history)
        case .tasks:
            action = .openWorkspace(.tasks)
        case .permissions:
            action = .openWorkspace(.permissions)
        case .settings:
            action = .openWorkspace(.settings)
        }

        guard let action else { return }
        TravisUIActionRouter.shared.route(action)
        appState.selectedSidebarItem = .chat
    }
}
