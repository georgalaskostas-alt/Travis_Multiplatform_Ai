import Foundation

struct TravisPermission: Identifiable, Codable, Hashable {
    let id: UUID
    var capability: TravisCapability
    var policy: PermissionPolicy
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        capability: TravisCapability,
        policy: PermissionPolicy,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.capability = capability
        self.policy = policy
        self.isEnabled = isEnabled
    }
}

enum TravisCapability: String, Codable, CaseIterable, Identifiable {
    case fileAccess
    case xcodeAutomation
    case emailAccess
    case stockMonitoring
    case notifications
    case internetAccess
    case systemActions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileAccess: return "File Access"
        case .xcodeAutomation: return "Xcode Automation"
        case .emailAccess: return "Email Access"
        case .stockMonitoring: return "Stock Monitoring"
        case .notifications: return "Notifications"
        case .internetAccess: return "Internet Access"
        case .systemActions: return "System Actions"
        }
    }
}

enum PermissionPolicy: String, Codable, CaseIterable, Identifiable {
    case blocked
    case askEveryTime
    case allowForSession
    case alwaysAllow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blocked: return "Blocked"
        case .askEveryTime: return "Ask Every Time"
        case .allowForSession: return "Allow For Session"
        case .alwaysAllow: return "Always Allow"
        }
    }
}

extension TravisPermission {
    static let defaultPermissions: [TravisPermission] = [
        TravisPermission(capability: .fileAccess, policy: .askEveryTime),
        TravisPermission(capability: .xcodeAutomation, policy: .askEveryTime),
        TravisPermission(capability: .emailAccess, policy: .blocked),
        TravisPermission(capability: .stockMonitoring, policy: .allowForSession),
        TravisPermission(capability: .notifications, policy: .alwaysAllow),
        TravisPermission(capability: .internetAccess, policy: .alwaysAllow),
        TravisPermission(capability: .systemActions, policy: .blocked)
    ]
}
