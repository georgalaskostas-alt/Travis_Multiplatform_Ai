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
    func handleDeterministicNavigationIntent(_ text: String, recordConversation: Bool = true) -> Bool {
        guard let action = TravisNavigationIntentParser.action(for: text) else { return false }

        if recordConversation {
            appendMessage(role: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        performUIAction(action)

        let response = localUIActionResponse(action)
        if recordConversation, !response.isEmpty {
            addAssistantMessage(response)
        }
        lastResponseSummary = response.isEmpty ? "Local UI action" : response
        return true
    }

    private func localUIActionResponse(_ action: TravisUIAction) -> String {
        switch action {
        case .openWorkspace(.dashboard): return "Άνοιξα το TRAVIS Dashboard."
        case .openWorkspace(.chat): return "Άνοιξα το TRAVIS Chat."
        case .openWorkspace(.history): return "Άνοιξα το ιστορικό συνομιλιών."
        case .openWorkspace(.tasks): return "Άνοιξα το Task Control."
        case .openWorkspace(.fcc): return "Άνοιξα το FCC Assistant workspace."
        case .openWorkspace(.memory): return "Άνοιξα το Learning & Memory workspace."
        case .openWorkspace(.permissions): return "Άνοιξα τα Permissions."
        case .openWorkspace(.settings): return "Άνοιξα τα Settings."
        case .closeWorkspace(let workspace): return "Έκλεισα το \(workspace.rawValue) workspace."
        case .minimizeWorkspace(let workspace): return "Ελαχιστοποίησα το \(workspace.rawValue) workspace."
        case .maximizeWorkspace(let workspace): return "Μεγιστοποίησα το \(workspace.rawValue) workspace."
        case .restoreWorkspace(let workspace): return "Επανέφερα το \(workspace.rawValue) workspace."
        case .bringWorkspaceToFront(let workspace): return "Έφερα μπροστά το \(workspace.rawValue) workspace."
        case .newMission: return "Άνοιξα νέα αποστολή."
        case .newProject: return "Άνοιξα νέο project."
        case .systemScan: return "Ετοίμασα System Scan."
        case .toggleVoice: return isListening ? "Voice control ενεργό." : "Voice control ανενεργό."
        }
    }
}
