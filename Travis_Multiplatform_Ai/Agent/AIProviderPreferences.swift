import Foundation

/// Lightweight local preferences for optional AI providers. Secrets stay in
/// Keychain; this store contains only model identifiers/endpoints and routing
/// toggles so provider policy can evolve without touching capabilities.
struct AIProviderPreferences {
    private enum Key {
        static let openRouterEconomyModel = "ai.openrouter.economyModel"
        static let openRouterStandardModel = "ai.openrouter.standardModel"
        static let openRouterStrongModel = "ai.openrouter.strongModel"
        static let localBaseURL = "ai.local.baseURL"
        static let localModel = "ai.local.model"
        static let localEnabled = "ai.local.enabled"
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var openRouterEconomyModel: String? { normalized(defaults.string(forKey: Key.openRouterEconomyModel)) }
    var openRouterStandardModel: String? { normalized(defaults.string(forKey: Key.openRouterStandardModel)) }
    var openRouterStrongModel: String? { normalized(defaults.string(forKey: Key.openRouterStrongModel)) }

    var localEnabled: Bool { defaults.bool(forKey: Key.localEnabled) }
    var localBaseURL: URL? {
        guard localEnabled, let value = normalized(defaults.string(forKey: Key.localBaseURL)) else { return nil }
        return URL(string: value)
    }
    var localModel: String? {
        guard localEnabled else { return nil }
        return normalized(defaults.string(forKey: Key.localModel))
    }

    func openRouterModel(for workload: AIWorkloadClass) -> String? {
        switch workload {
        case .classification:
            return openRouterEconomyModel ?? openRouterStandardModel
        case .routine:
            return openRouterStandardModel ?? openRouterEconomyModel
        case .complex, .verification, .frontier, .webResearch:
            return openRouterStrongModel
        case .deterministic:
            return nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
