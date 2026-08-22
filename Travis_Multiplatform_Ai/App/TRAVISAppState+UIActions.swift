import Foundation

@MainActor
extension TRAVISAppState {
    func performUIAction(_ action: TravisUIAction) {
        switch action {
        case .openWorkspace(.dashboard):
            selectedSidebarItem = .chat
            TravisUIActionRouter.shared.route(action)

        case .openWorkspace(.permissions):
            selectedSidebarItem = .permissions

        case .openWorkspace(.settings):
            selectedSidebarItem = .settings

        case .openWorkspace(.history):
            selectedSidebarItem = .chat
            TravisUIActionRouter.shared.route(action)

        case .openWorkspace(.tasks), .openWorkspace(.chat), .openWorkspace(.fcc), .openWorkspace(.memory):
            selectedSidebarItem = .chat
            TravisUIActionRouter.shared.route(action)

        case .closeWorkspace, .minimizeWorkspace, .maximizeWorkspace, .restoreWorkspace, .bringWorkspaceToFront:
            selectedSidebarItem = .chat
            TravisUIActionRouter.shared.route(action)

        case .newMission:
            selectedSidebarItem = .chat
            chatInput = "/plan "
            TravisUIActionRouter.shared.route(.openWorkspace(.chat))

        case .newProject:
            selectedSidebarItem = .chat
            chatInput = "Φτιάξε project "
            TravisUIActionRouter.shared.route(.openWorkspace(.chat))

        case .systemScan:
            selectedSidebarItem = .chat
            chatInput = "Έλεγξε την κατάσταση του συστήματος"
            TravisUIActionRouter.shared.route(.openWorkspace(.chat))

        case .toggleVoice:
            toggleListening()
        }
    }

    @discardableResult
    func handleDeterministicNavigationIntent(_ text: String) -> Bool {
        guard let action = TravisNavigationIntentParser.action(for: text) else { return false }
        performUIAction(action)
        lastResponseSummary = "Local UI action: \(String(describing: action))"
        return true
    }
}
