import Foundation

enum SidebarItem: String, Codable, CaseIterable, Identifiable, Hashable {
    case chat
    case tasks
    case permissions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .tasks: return "Tasks"
        case .permissions: return "Permissions"
        case .settings: return "Settings"
        }
    }
}
