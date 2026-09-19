import Foundation
import Observation

enum SidebarItem: String, Codable, CaseIterable, Identifiable, Hashable {
    case chat
    case history
    case tasks
    case permissions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .history: return "Ιστορικό"
        case .tasks: return "Tasks"
        case .permissions: return "Permissions"
        case .settings: return "Settings"
        }
    }
}

enum TravisWorkspaceID: String, Codable, CaseIterable, Sendable {
    case dashboard
    case chat
    case history
    case tasks
    case fcc
    case memory
    case permissions
    case settings
}

enum TravisUIAction: Equatable, Sendable {
    case openWorkspace(TravisWorkspaceID)
    case closeWorkspace(TravisWorkspaceID)
    case minimizeWorkspace(TravisWorkspaceID)
    case maximizeWorkspace(TravisWorkspaceID)
    case restoreWorkspace(TravisWorkspaceID)
    case bringWorkspaceToFront(TravisWorkspaceID)
    case newMission
    case newProject
    case systemScan
    case toggleVoice
}

struct TravisUIActionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: TravisUIAction

    init(action: TravisUIAction) {
        self.id = UUID()
        self.action = action
    }
}

@MainActor
@Observable
final class TravisUIActionRouter {
    static let shared = TravisUIActionRouter()

    private(set) var pendingRequest: TravisUIActionRequest?

    private init() {}

    func route(_ action: TravisUIAction) {
        pendingRequest = TravisUIActionRequest(action: action)
    }

    func consume(_ requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
    }
}

enum TravisNavigationIntentParser {
    static func action(for rawText: String) -> TravisUIAction? {
        let text = normalize(rawText)

        let exactOpen: [String: TravisWorkspaceID] = [
            "open chat": .chat,
            "open tasks": .tasks,
            "open history": .history,
            "open settings": .settings,
            "open permissions": .permissions,
            "open memory": .memory,
            "open fcc": .fcc,
            "open fcc assistant": .fcc,
            "show dashboard": .dashboard,
            "ανοιξε το chat": .chat,
            "ανοιξε τις εργασιες": .tasks,
            "ανοιξε το ιστορικο": .history,
            "ανοιξε τις ρυθμισεις": .settings,
            "ανοιξε τις αδειες": .permissions,
            "ανοιξε τη μνημη": .memory,
            "ανοιξε το fcc": .fcc,
            "ανοιξε το fcc assistant": .fcc,
            "δειξε το dashboard": .dashboard
        ]
        if let workspace = exactOpen[text] { return .openWorkspace(workspace) }

        let exactClose: [String: TravisWorkspaceID] = [
            "close chat": .chat,
            "close tasks": .tasks,
            "close history": .history,
            "close fcc": .fcc,
            "close memory": .memory,
            "κλεισε το chat": .chat,
            "κλεισε τις εργασιες": .tasks,
            "κλεισε το ιστορικο": .history,
            "κλεισε το fcc": .fcc,
            "κλεισε τη μνημη": .memory
        ]
        if let workspace = exactClose[text] { return .closeWorkspace(workspace) }

        let exactMinimize: [String: TravisWorkspaceID] = [
            "minimize chat": .chat,
            "minimize tasks": .tasks,
            "minimize history": .history,
            "minimize fcc": .fcc,
            "minimize memory": .memory,
            "ελαχιστοποιησε το chat": .chat,
            "ελαχιστοποιησε τις εργασιες": .tasks,
            "ελαχιστοποιησε το ιστορικο": .history,
            "ελαχιστοποιησε το fcc": .fcc,
            "ελαχιστοποιησε τη μνημη": .memory
        ]
        if let workspace = exactMinimize[text] { return .minimizeWorkspace(workspace) }

        switch text {
        case "new mission", "νεα αποστολη": return .newMission
        case "new project", "νεο project", "νεο εργο": return .newProject
        case "system scan", "ελεγχος συστηματος": return .systemScan
        case "toggle voice", "φωνη": return .toggleVoice
        default: return nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

@MainActor
extension TRAVISAppState {
    func performUIAction(_ action: TravisUIAction) {
        switch action {
        case .openWorkspace(.dashboard):
            selectedSidebarItem = .chat
            TravisUIActionRouter.shared.route(action)
        case .openWorkspace(.permissions):
            selectedSidebarItem = .permissions
            TravisUIActionRouter.shared.route(action)
        case .openWorkspace(.settings):
            selectedSidebarItem = .settings
            TravisUIActionRouter.shared.route(action)
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
            runLocalSystemScan()
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
        case .systemScan: return "Ολοκλήρωσα το τοπικό System Check."
        case .toggleVoice: return isListening ? "Voice control ενεργό." : "Voice control ανενεργό."
        }
    }
}
