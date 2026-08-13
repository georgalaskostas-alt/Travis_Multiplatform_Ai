import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.konstantinos.Travis-Multiplatform-Ai"
    private let apiKeyAccount = "anthropic-api-key"
    /// Distinct Keychain accounts from any future live-trading credential
    /// — never reused, never shared, so a testnet key can never be
    /// accidentally treated as a live one or vice versa.
    private let binanceTestnetAPIKeyAccount = "binance-testnet-api-key"
    private let binanceTestnetAPISecretAccount = "binance-testnet-api-secret"

    private init() {}

    var anthropicAPIKey: String? {
        read(account: apiKeyAccount)
    }

    func saveAnthropicAPIKey(_ key: String) {
        save(key, account: apiKeyAccount)
    }

    func deleteAnthropicAPIKey() {
        delete(account: apiKeyAccount)
    }

    var binanceTestnetAPIKey: String? {
        read(account: binanceTestnetAPIKeyAccount)
    }

    func saveBinanceTestnetAPIKey(_ key: String) {
        save(key, account: binanceTestnetAPIKeyAccount)
    }

    func deleteBinanceTestnetAPIKey() {
        delete(account: binanceTestnetAPIKeyAccount)
    }

    var binanceTestnetAPISecret: String? {
        read(account: binanceTestnetAPISecretAccount)
    }

    func saveBinanceTestnetAPISecret(_ secret: String) {
        save(secret, account: binanceTestnetAPISecretAccount)
    }

    func deleteBinanceTestnetAPISecret() {
        delete(account: binanceTestnetAPISecretAccount)
    }

    private func save(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
