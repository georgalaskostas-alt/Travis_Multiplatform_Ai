import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.konstantinos.Travis-Multiplatform-Ai"
    private let anthropicAPIKeyAccount = "anthropic-api-key"
    private let openAIAPIKeyAccount = "openai-api-key"
    private let openRouterAPIKeyAccount = "openrouter-api-key"
    private let githubTokenAccount = "github-token"

    /// Distinct Keychain accounts from any future live-trading credential
    /// — never reused, never shared, so a testnet key can never be
    /// accidentally treated as a live one or vice versa.
    private let binanceTestnetAPIKeyAccount = "binance-testnet-api-key"
    private let binanceTestnetAPISecretAccount = "binance-testnet-api-secret"

    private init() {}

    // MARK: - AI Providers

    var openAIAPIKey: String? { read(account: openAIAPIKeyAccount) }
    func saveOpenAIAPIKey(_ key: String) { save(key, account: openAIAPIKeyAccount) }
    func deleteOpenAIAPIKey() { delete(account: openAIAPIKeyAccount) }

    var anthropicAPIKey: String? { read(account: anthropicAPIKeyAccount) }
    func saveAnthropicAPIKey(_ key: String) { save(key, account: anthropicAPIKeyAccount) }
    func deleteAnthropicAPIKey() { delete(account: anthropicAPIKeyAccount) }

    var openRouterAPIKey: String? { read(account: openRouterAPIKeyAccount) }
    func saveOpenRouterAPIKey(_ key: String) { save(key, account: openRouterAPIKeyAccount) }
    func deleteOpenRouterAPIKey() { delete(account: openRouterAPIKeyAccount) }

    // MARK: - GitHub

    var githubToken: String? { read(account: githubTokenAccount) }
    func saveGitHubToken(_ token: String) { save(token, account: githubTokenAccount) }
    func deleteGitHubToken() { delete(account: githubTokenAccount) }

    // MARK: - Binance Testnet

    var binanceTestnetAPIKey: String? { read(account: binanceTestnetAPIKeyAccount) }
    func saveBinanceTestnetAPIKey(_ key: String) { save(key, account: binanceTestnetAPIKeyAccount) }
    func deleteBinanceTestnetAPIKey() { delete(account: binanceTestnetAPIKeyAccount) }

    var binanceTestnetAPISecret: String? { read(account: binanceTestnetAPISecretAccount) }
    func saveBinanceTestnetAPISecret(_ secret: String) { save(secret, account: binanceTestnetAPISecretAccount) }
    func deleteBinanceTestnetAPISecret() { delete(account: binanceTestnetAPISecretAccount) }

    // MARK: - Generic Keychain Helpers

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
