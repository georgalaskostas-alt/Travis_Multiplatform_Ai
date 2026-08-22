import Foundation

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
            .replacingOccurrences(of: "  ", with: " ")
    }
}
