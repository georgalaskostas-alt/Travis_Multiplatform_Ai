import SwiftUI

struct SettingsView: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        Form {
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
