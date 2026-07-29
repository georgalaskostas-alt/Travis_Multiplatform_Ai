import Foundation

final class PermissionService {
    static let shared = PermissionService()

    private init() {}

    func canUse(_ capability: TravisCapability, permissions: [TravisPermission]) -> Bool {
        guard let permission = permissions.first(where: { $0.capability == capability }) else {
            return false
        }

        guard permission.isEnabled else { return false }

        switch permission.policy {
        case .blocked:
            return false
        case .askEveryTime:
            return false
        case .allowForSession, .alwaysAllow:
            return true
        }
    }

    func policyTitle(for capability: TravisCapability, permissions: [TravisPermission]) -> String {
        guard let permission = permissions.first(where: { $0.capability == capability }) else {
            return "Blocked"
        }
        return permission.policy.title
    }
}
