import SwiftUI

struct SettingsView: View {
    @Bindable var appState: TRAVISAppState
    @State private var openAIAPIKey: String = KeychainService.shared.openAIAPIKey ?? ""
    @State private var openRouterAPIKey: String = KeychainService.shared.openRouterAPIKey ?? ""
    @State private var githubToken: String = KeychainService.shared.githubToken ?? ""

    @AppStorage("ai.openrouter.economyModel") private var openRouterEconomyModel = ""
    @AppStorage("ai.openrouter.standardModel") private var openRouterStandardModel = ""
    @AppStorage("ai.openrouter.strongModel") private var openRouterStrongModel = ""
    @AppStorage("ai.local.enabled") private var localAIEnabled = false
    @AppStorage("ai.local.baseURL") private var localAIBaseURL = "http://127.0.0.1:11434"
    @AppStorage("ai.local.model") private var localAIModel = ""

    private static let mandateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()

    private static func modeAndAsset(from mandateKey: String) -> (mode: String, asset: String) {
        let prefix = "trading_"
        guard mandateKey.hasPrefix(prefix) else { return ("", mandateKey) }
        let remainder = mandateKey.dropFirst(prefix.count)
        for mode in TradingMode.allCases {
            let modePrefix = "\(mode.rawValue)_"
            if remainder.hasPrefix(modePrefix) {
                return (mode.title, String(remainder.dropFirst(modePrefix.count)))
            }
        }
        return ("", String(remainder))
    }

    var body: some View {
        Form {
            Section("OpenAI Direct") {
                SecureField("OpenAI API Key", text: $openAIAPIKey)
                    .onChange(of: openAIAPIKey) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { KeychainService.shared.deleteOpenAIAPIKey() }
                        else { KeychainService.shared.saveOpenAIAPIKey(trimmed) }
                    }

                Text("Direct strong-provider path. Ο cost router μπορεί να χρησιμοποιεί φθηνότερο local/OpenRouter tier πρώτα και να κλιμακώνει εδώ όταν χρειάζεται.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenRouter — Optional Cost Tier") {
                SecureField("OpenRouter API Key", text: $openRouterAPIKey)
                    .onChange(of: openRouterAPIKey) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { KeychainService.shared.deleteOpenRouterAPIKey() }
                        else { KeychainService.shared.saveOpenRouterAPIKey(trimmed) }
                    }

                TextField("Economy model ID", text: $openRouterEconomyModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Standard model ID", text: $openRouterStandardModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Strong model ID", text: $openRouterStrongModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Ο TRAVIS δεν hard-codeάρει OpenRouter model IDs. Συμπλήρωσε μόνο μοντέλα που θέλεις να χρησιμοποιούνται. Κενό πεδίο = αυτό το tier παραλείπεται.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local AI — Optional") {
                Toggle("Enable local AI", isOn: $localAIEnabled)
                TextField("Base URL", text: $localAIBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Local model ID", text: $localAIModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Χρησιμοποιείται μόνο για classification/routine workloads και μόνο μέσω OpenAI-compatible chat-completions endpoint. Αν αποτύχει, ο router κλιμακώνει στο επόμενο διαθέσιμο tier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anthropic Direct — Fallback") {
                SecureField("Anthropic API Key", text: $appState.anthropicAPIKey)
                Text("Cross-provider fallback για reliability ή strong reasoning όταν προηγούμενα tiers αποτύχουν.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GitHub Coding") {
                SecureField("GitHub Fine-grained Token", text: $githubToken)
                    .onChange(of: githubToken) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { KeychainService.shared.deleteGitHubToken() }
                        else { KeychainService.shared.saveGitHubToken(trimmed) }
                    }

                Text("Χρησιμοποιείται μόνο για approved source-code commits από το coding_repository capability. Read-only repository analysis δεν χρειάζεται write token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Assistant") {
                TextField("Assistant Name", text: $appState.assistantName)

                Picker("Language", selection: $appState.preferredLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }

                Toggle("Internet Access", isOn: $appState.isInternetEnabled)
            }

            Section("Voice") {
                Toggle("Listening Mode", isOn: $appState.isListening)
                Toggle("Processing State", isOn: $appState.isProcessing)

                Button("Δοκίμασε τη φωνή") {
                    SpeechService.shared.speak(
                        "Γεια σου, είμαι ο \(appState.assistantName). Έτοιμος να βοηθήσω.",
                        language: appState.preferredLanguage
                    )
                }
            }

            Section("Binance Testnet API") {
                SecureField("Binance Testnet API Key", text: $appState.binanceTestnetAPIKey)
                SecureField("Binance Testnet API Secret", text: $appState.binanceTestnetAPISecret)

                Text("Ξεχωριστά credentials, μόνο για το Binance SPOT TESTNET — ποτέ δεν επαναχρησιμοποιούνται σαν live credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trading Mandates") {
                if appState.tradingMandates.isEmpty {
                    Text("Δεν υπάρχουν ενεργά trading mandates ακόμα.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.tradingMandates, id: \.key) { mandate in
                        let parsed = Self.modeAndAsset(from: mandate.key)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parsed.mode.isEmpty ? parsed.asset : "\(parsed.asset) — \(parsed.mode)")
                                Text("Από " + Self.mandateDateFormatter.string(from: mandate.grantedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Ανάκληση", role: .destructive) {
                                appState.revokeTradingMandate(mandate)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .onAppear { appState.refreshTradingMandates() }

            Section("AI Routing Status") {
                Text(localAIEnabled && !localAIModel.isEmpty ? "Tier 0/1: Local configured" : "Tier 0/1: Local disabled/not configured")
                Text(openRouterAPIKey.isEmpty ? "Economy/standard: OpenRouter not configured" : "Economy/standard: OpenRouter key configured")
                Text(openAIAPIKey.isEmpty ? "Direct OpenAI: not configured" : "Direct OpenAI: configured")
                Text(appState.anthropicAPIKey.isEmpty ? "Anthropic fallback: not configured" : "Anthropic fallback: configured")
                Text(githubToken.isEmpty ? "GitHub coding: read-only" : "GitHub coding: write token configured")
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text("Current State: \(appState.currentDeviceState.title)")
                Text("Summary: \(appState.lastResponseSummary)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
