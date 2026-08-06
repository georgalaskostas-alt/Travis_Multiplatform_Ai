import Foundation

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
