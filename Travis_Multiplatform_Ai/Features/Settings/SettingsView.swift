import SwiftUI

struct SettingsView: View {
    @Bindable var appState: TRAVISAppState

    private static let mandateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()

    /// Splits a `"trading_paper_XRP"`/`"trading_testnet_XRP"` mandate key
    /// into its mode and asset for display — mirrors
    /// `CryptoTradingCapability.parseMandateKey`. Falls back to showing
    /// the raw remainder with no mode label for any key that predates
    /// the mode-scoped scheme, rather than looking broken.
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
            Section("Anthropic API") {
                SecureField("API Key", text: $appState.anthropicAPIKey)

                if appState.anthropicAPIKey.isEmpty {
                    Text("Χρειάζεται Anthropic API key για να λειτουργήσουν οι AI δυνατότητες.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

                Text("Ξεχωριστά credentials, μόνο για το Binance SPOT TESTNET (testnet.binance.vision) — ποτέ δεν θα μπερδευτούν με κάποιο μελλοντικό live API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trading Mandates") {
                if appState.tradingMandates.isEmpty {
                    Text("Δεν υπάρχουν ενεργά trading mandates ακόμα — δίνονται αυτόματα την πρώτη φορά που εγκρίνεις trading (paper ή testnet) σε ένα asset. Το testnet χρειάζεται πάντα δική του ξεχωριστή άδεια, ακόμα κι αν υπάρχει ήδη mandate σε paper για το ίδιο asset.")
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

            Section("Status") {
                Text("Current State: \(appState.currentDeviceState.title)")
                Text("Summary: \(appState.lastResponseSummary)")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
