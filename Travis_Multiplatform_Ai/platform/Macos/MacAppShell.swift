import SwiftUI

struct MacAppShell: View {
    @Bindable var appState: TRAVISAppState
    @State private var openFCCQuickAccess = false

    var body: some View {
        Group {
            if appState.selectedSidebarItem == .chat {
                TravisWorkspaceLayer(appState: appState, openFCCQuickAccess: $openFCCQuickAccess) {
                    TravisPremiumCommandCenterView(appState: appState)
                }
            } else {
                NavigationSplitView {
                    List(SidebarItem.allCases, selection: $appState.selectedSidebarItem) { item in
                        Label(item.title, systemImage: icon(for: item))
                            .tag(item)
                            .help(tooltip(for: item))
                    }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                } detail: {
                    detailView(for: appState.selectedSidebarItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFCCWorkspace()
                } label: {
                    Label("FCC", systemImage: "waveform.path.ecg")
                }
                .help("Open FCC Assistant workspace")
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .chat:
            ChatView(appState: appState)
        case .history:
            ChatHistoryView(appState: appState)
        case .tasks:
            taskPanel
        case .permissions:
            PermissionsView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }

    private var taskPanel: some View {
        List(appState.activeTasks) { task in
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(.headline)
                Text(task.details).font(.subheadline).foregroundStyle(.secondary)
                Text("\(task.status.rawValue) • \(task.priority.rawValue)").font(.caption).foregroundStyle(.cyan)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Tasks")
    }

    private func showFCCWorkspace() {
        openFCCQuickAccess = true
        appState.selectedSidebarItem = .chat
    }

    private func tooltip(for item: SidebarItem) -> String {
        switch item {
        case .chat: return "Open the TRAVIS command center and chat workspace"
        case .history: return "Review previous TRAVIS conversations and activity"
        case .tasks: return "View active and recent autonomous tasks"
        case .permissions: return "Review and manage TRAVIS execution permissions"
        case .settings: return "Open TRAVIS settings"
        }
    }

    private func icon(for item: SidebarItem) -> String {
        switch item {
        case .chat: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "checklist"
        case .permissions: return "lock.shield"
        case .settings: return "gearshape"
        }
    }
}
