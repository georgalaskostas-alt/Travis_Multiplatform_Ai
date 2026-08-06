import SwiftUI

struct iOSAppShell: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        TabView(selection: $appState.selectedSidebarItem) {
            NavigationStack {
                ChatView(appState: appState)
                    .navigationTitle("Travis")
            }
            .tabItem {
                Label("Chat", systemImage: "message")
            }
            .tag(SidebarItem.chat)

            NavigationStack {
                ChatHistoryView(appState: appState)
            }
            .tabItem {
                Label("Ιστορικό", systemImage: "clock.arrow.circlepath")
            }
            .tag(SidebarItem.history)

            NavigationStack {
                PermissionsView(appState: appState)
            }
            .tabItem {
                Label("Permissions", systemImage: "lock.shield")
            }
            .tag(SidebarItem.permissions)

            NavigationStack {
                SettingsView(appState: appState)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(SidebarItem.settings)
        }
        .preferredColorScheme(.dark)
    }
}
