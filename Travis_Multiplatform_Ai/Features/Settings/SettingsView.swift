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

    private static func assetName(from mandateKey: String) -> String {
        let prefix = "trading_"
        return mandateKey.hasPrefix(prefix) ? String(mandateKey.dropFirst(prefix.count)) : mandateKey
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

            Section("Trading Mandates (Paper)") {
                if appState.tradingMandates.isEmpty {
                    Text("Δεν υπάρχουν ενεργά trading mandates ακόμα — δίνονται αυτόματα την πρώτη φορά που εγκρίνεις trading σε ένα asset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.tradingMandates, id: \.key) { mandate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.assetName(from: mandate.key))
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
