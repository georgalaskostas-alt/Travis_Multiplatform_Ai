import Foundation
import Security

/// Keychain-backed storage for the authenticated TRAVIS Supabase session.
/// Access and refresh tokens are secrets and never belong in UserDefaults,
/// source control, logs, or application diagnostics.
enum TravisCloudCredentialStore {

    struct Session: Codable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date

        var needsRefresh: Bool {
            // Refresh early so an in-flight Control Plane request does not
            // cross the token expiry boundary.
            Date().addingTimeInterval(60) >= expiresAt
        }
    }

    private static let service = "com.travis.control-plane"

    // Preserve the original account name so an existing access token, if one
    // exists on a developer machine, can be migrated without exposing it.
    private static let legacyAccessTokenAccount = "supabase-user-access-token"
    private static let sessionAccount = "supabase-user-session-v1"
    private static let bridgePairingAccount = "lan-bridge-pairing-token-v1"

    static func save(session: Session) throws {
        let data = try JSONEncoder().encode(session)
        try write(data, account: sessionAccount)

        // Once the complete renewable session is durable, the legacy
        // access-token-only entry is no longer needed.
        delete(account: legacyAccessTokenAccount)
    }

    static func loadSession() -> Session? {
        guard let data = read(account: sessionAccount) else {
            return nil
        }

        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// Compatibility accessor used by the current Control Plane startup.
    /// It deliberately returns nil for expired/near-expiry sessions.
    static func load() -> String? {
        guard let session = loadSession(),
              !session.needsRefresh else {
            return nil
        }

        return session.accessToken
    }

    static func clear() {
        delete(account: sessionAccount)
        delete(account: legacyAccessTokenAccount)
    }

    static func saveBridgePairingToken(_ token: String) throws {
        try write(Data(token.utf8), account: bridgePairingAccount)
    }

    static func loadBridgePairingToken() -> String? {
        guard let data = read(account: bridgePairingAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clearBridgePairingToken() {
        delete(account: bridgePairingAccount)
    }

    private static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw StoreError.status(status)
        }
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?

        guard SecItemCopyMatching(
            query as CFDictionary,
            &item
        ) == errSecSuccess,
        let data = item as? Data else {
            return nil
        }

        return data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    enum StoreError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                return "Keychain error \(status)"
            }
        }
    }
}
