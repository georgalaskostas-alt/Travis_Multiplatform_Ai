import SwiftUI

struct SettingsView: View {
    @Bindable var appState: TRAVISAppState
    @State private var openAIAPIKey: String = KeychainService.shared.openAIAPIKey ?? ""
    @State private var openRouterAPIKey: String = KeychainService.shared.openRouterAPIKey ?? ""
    @State private var githubToken: String = KeychainService.shared.githubToken ?? ""
    @State private var startupAudioConfigured = false
    @State private var voiceReferenceConfigured = false
    @State private var cloudAuthBusy = false
    @State private var cloudAuthMessage: String?
    @State private var lanPairingCode = ""

    @AppStorage("ai.openrouter.economyModel") private var openRouterEconomyModel = ""
    @AppStorage("ai.openrouter.standardModel") private var openRouterStandardModel = ""
    @AppStorage("ai.openrouter.strongModel") private var openRouterStrongModel = ""
    @AppStorage("ai.local.enabled") private var localAIEnabled = false
    @AppStorage("ai.local.baseURL") private var localAIBaseURL = "http://127.0.0.1:11434"
    @AppStorage("ai.local.model") private var localAIModel = ""
    @AppStorage("ai.budget.dailyTokens") private var dailyTokenBudget = 0
    @AppStorage("ai.budget.monthlyTokens") private var monthlyTokenBudget = 0
    @AppStorage("ai.budget.dailyCostUSD") private var dailyCostBudgetUSD = 0.0
    @AppStorage("ai.budget.monthlyCostUSD") private var monthlyCostBudgetUSD = 0.0
    @AppStorage("training.local.baseURL") private var localTrainerBaseURL = "http://127.0.0.1:8765"
    @AppStorage("voice.startupGreetingText") private var startupGreetingText = "Καλώς ήρθες. Όλα τα συστήματα είναι έτοιμα. TRAVIS online."

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
        ScrollView(.vertical) {
            Form {
                Section("OpenAI Direct") {
                    SecureField("OpenAI API Key", text: $openAIAPIKey)
                        .onChange(of: openAIAPIKey) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { KeychainService.shared.deleteOpenAIAPIKey() }
                            else { try? KeychainService.shared.saveOpenAIAPIKey(trimmed) }
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
                            else { try? KeychainService.shared.saveOpenRouterAPIKey(trimmed) }
                        }

                    TextField("Economy model ID", text: $openRouterEconomyModel)
                    TextField("Standard model ID", text: $openRouterStandardModel)
                    TextField("Strong model ID", text: $openRouterStrongModel)

                    Text("Ο TRAVIS δεν hard-codeάρει OpenRouter model IDs. Συμπλήρωσε μόνο μοντέλα που θέλεις να χρησιμοποιούνται. Κενό πεδίο = αυτό το tier παραλείπεται.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Local AI — Optional") {
                    Toggle("Enable local AI", isOn: $localAIEnabled)
                    TextField("Base URL", text: $localAIBaseURL)
                    TextField("Local model ID", text: $localAIModel)

                    Text("Χρησιμοποιείται μόνο για classification/routine workloads και μόνο μέσω OpenAI-compatible chat-completions endpoint. Αν αποτύχει, ο router κλιμακώνει στο επόμενο διαθέσιμο tier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI Cost Guard") {
                    TextField("Daily token ceiling (0 = disabled)", value: $dailyTokenBudget, format: .number)
                    TextField("Monthly token ceiling (0 = disabled)", value: $monthlyTokenBudget, format: .number)
                    TextField("Daily cost ceiling USD (0 = disabled)", value: $dailyCostBudgetUSD, format: .number.precision(.fractionLength(2...4)))
                    TextField("Monthly cost ceiling USD (0 = disabled)", value: $monthlyCostBudgetUSD, format: .number.precision(.fractionLength(2...4)))

                    Text("Τα global ceilings ελέγχονται πριν από κάθε AI request. Dollar ceilings εφαρμόζονται fail-closed: αν κάποιο χρησιμοποιημένο model δεν έχει configured pricing, ο TRAVIS δεν προσποιείται ότι το άγνωστο κόστος είναι μηδέν.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Local Training Worker") {
                    TextField("Trainer localhost URL", text: $localTrainerBaseURL)
                    Text("Ο trainer bridge δέχεται μόνο localhost/127.0.0.1/::1. Training, evaluation και promotion είναι ξεχωριστά gated stages.")
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
                            else { try? KeychainService.shared.saveGitHubToken(trimmed) }
                        }

                    Text("Χρησιμοποιείται μόνο για approved source-code commits από το coding_repository capability. Read-only repository analysis δεν χρειάζεται write token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("TRAVIS Cloud Account") {
                    HStack(spacing: 10) {
                        Image(systemName: cloudStatusSymbol)
                            .foregroundStyle(cloudStatusColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(cloudStatusTitle)
                                .font(.headline)

                            Text(cloudStatusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if cloudAuthBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if TravisCloudAuthService.shared.isSignedIn {
                        HStack {
                            Button("Refresh Session") {
                                Task {
                                    await refreshCloudSession()
                                }
                            }
                            .disabled(cloudAuthBusy)

                            Spacer()

                            Button("Sign Out", role: .destructive) {
                                signOutCloud()
                            }
                            .disabled(cloudAuthBusy)
                        }
                    } else {
                        Button {
                            Task {
                                await signInCloudWithGitHub()
                            }
                        } label: {
                            Label(
                                "Continue with GitHub",
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .disabled(cloudAuthBusy)
                    }

                    if let cloudAuthMessage {
                        Text(cloudAuthMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Text(
                        "Η σύνδεση γίνεται μέσω GitHub και Supabase OAuth. "
                        + "Ο TRAVIS δεν βλέπει ούτε αποθηκεύει GitHub password. "
                        + "Το renewable Supabase session παραμένει στο Keychain "
                        + "αυτής της συσκευής."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Secure Mac ↔ iPhone LAN Pairing") {
#if os(macOS)
                    Text("Pairing code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(TravisDeviceBridgeService.shared.lanPairingCode)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Generate New Pairing Code", role: .destructive) {
                        TravisDeviceBridgeService.shared.rotateLANPairingCode()
                    }
                    Text("Enter this code once on your iPhone. Generating a new code immediately invalidates the previous LAN trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#elseif os(iOS)
                    SecureField("Pairing code from Mac", text: $lanPairingCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button(TravisDeviceBridgeService.shared.isLANPaired ? "Update Pairing" : "Pair with Mac") {
                            TravisDeviceBridgeService.shared.pairLAN(with: lanPairingCode)
                            lanPairingCode = ""
                        }
                        .disabled(lanPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if TravisDeviceBridgeService.shared.isLANPaired {
                            Button("Forget Mac", role: .destructive) {
                                TravisDeviceBridgeService.shared.forgetLANPairing()
                            }
                        }
                    }
                    Text(TravisDeviceBridgeService.shared.isLANPaired ? "This iPhone has a trusted LAN pairing secret in Keychain." : "Pair once using the code shown in TRAVIS Settings on the Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
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

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Startup greeting")
                            .font(.headline)
                        Text("Το κείμενο που θα λέει ο TRAVIS στην εκκίνηση.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $startupGreetingText)
                            .frame(minHeight: 90)
                            .padding(6)
                            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25), lineWidth: 1))
                    }

                    #if os(macOS)
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Private startup sound")
                            Text(startupAudioConfigured ? "Configured on this Mac" : "Not configured")
                                .font(.caption)
                                .foregroundStyle(startupAudioConfigured ? .green : .secondary)
                        }
                        Spacer()
                        Button("Choose Audio…") {
                            if PrivateAudioProfileService.shared.importPrivateAudio(kind: .startup) {
                                startupAudioConfigured = true
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Private voice reference")
                            Text(voiceReferenceConfigured ? "Configured on this Mac" : "Not configured")
                                .font(.caption)
                                .foregroundStyle(voiceReferenceConfigured ? .green : .secondary)
                        }
                        Spacer()
                        Button("Choose Voice…") {
                            if PrivateAudioProfileService.shared.importPrivateAudio(kind: .voiceReference) {
                                voiceReferenceConfigured = true
                            }
                        }
                    }

                    Text("These audio files stay inside this Mac's sandboxed TRAVIS data and are not included in GitHub or app releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
                .onAppear {
                    #if os(macOS)
                    startupAudioConfigured = PrivateAudioProfileService.shared.isConfigured(.startup)
                    voiceReferenceConfigured = PrivateAudioProfileService.shared.isConfigured(.voiceReference)
                    #endif
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
            .formStyle(.grouped)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
        .navigationTitle("Settings")
    }

    private var cloudStatusTitle: String {
        let auth = TravisCloudAuthService.shared

        if cloudAuthBusy {
            return "Connecting…"
        }

        if !auth.isSignedIn {
            return "Signed Out"
        }

#if os(macOS)
        switch TravisCloudControlPlane.shared.state {
        case .online:
            return "Cloud Online"
        case .connecting:
            return "Cloud Connecting"
        case .degraded:
            return "Cloud Degraded"
        case .unauthorized:
            return "Cloud Unauthorized"
        case .disabled:
            return "Signed In — Cloud Stopped"
        }
#else
        return "Signed In"
#endif
    }

    private var cloudStatusDetail: String {
#if os(macOS)
        let cloud = TravisCloudControlPlane.shared

        if let error = cloud.lastError, !error.isEmpty {
            return error
        }

        if let sync = cloud.lastSyncAt {
            return "Last heartbeat: \(sync.formatted(date: .abbreviated, time: .standard))"
        }

        return TravisCloudAuthService.shared.isSignedIn
            ? "Authenticated. Waiting for cloud heartbeat."
            : "Sign in to enable the WAN Control Plane."
#else
        return TravisCloudAuthService.shared.isSignedIn
            ? "Cloud session stored securely in Keychain."
            : "Sign in to TRAVIS Cloud."
#endif
    }

    private var cloudStatusSymbol: String {
        if cloudAuthBusy {
            return "arrow.triangle.2.circlepath"
        }

        if !TravisCloudAuthService.shared.isSignedIn {
            return "icloud.slash"
        }

#if os(macOS)
        switch TravisCloudControlPlane.shared.state {
        case .online:
            return "icloud.fill"
        case .connecting:
            return "icloud.and.arrow.up"
        case .degraded:
            return "exclamationmark.icloud"
        case .unauthorized:
            return "lock.icloud"
        case .disabled:
            return "icloud"
        }
#else
        return "icloud.fill"
#endif
    }

    private var cloudStatusColor: Color {
        if cloudAuthBusy {
            return .secondary
        }

        if !TravisCloudAuthService.shared.isSignedIn {
            return .secondary
        }

#if os(macOS)
        switch TravisCloudControlPlane.shared.state {
        case .online:
            return .green
        case .connecting:
            return .orange
        case .degraded, .unauthorized:
            return .red
        case .disabled:
            return .secondary
        }
#else
        return .green
#endif
    }

    @MainActor
    private func signInCloudWithGitHub() async {
        guard !cloudAuthBusy else { return }

        cloudAuthBusy = true
        cloudAuthMessage = nil

        defer {
            cloudAuthBusy = false
        }

        do {
            let session =
                try await TravisCloudAuthService.shared.signInWithGitHub()

#if os(macOS)
            startMacCloudControlPlane(
                accessToken: session.accessToken
            )
            cloudAuthMessage =
                "GitHub authenticated. Starting Cloud Control Plane…"
#else
            cloudAuthMessage =
                "GitHub authenticated successfully."
#endif
        } catch {
            cloudAuthMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshCloudSession() async {
        guard !cloudAuthBusy else { return }

        cloudAuthBusy = true
        cloudAuthMessage = nil

        defer {
            cloudAuthBusy = false
        }

        do {
            let session =
                try await TravisCloudAuthService.shared.refreshSession()

#if os(macOS)
            TravisCloudControlPlane.shared.stop()
            startMacCloudControlPlane(accessToken: session.accessToken)
            cloudAuthMessage = "Session refreshed. Cloud Control Plane restarted."
#else
            cloudAuthMessage = "Cloud session refreshed."
#endif
        } catch {
            cloudAuthMessage = error.localizedDescription
        }
    }

    @MainActor
    private func signOutCloud() {
#if os(macOS)
        TravisCloudControlPlane.shared.stop()
        TravisCloudControlPlane.shared.configure(accessToken: nil)
#endif

        TravisCloudAuthService.shared.signOut()

        cloudAuthMessage = "Signed out. Cloud credentials removed from Keychain."
    }

#if os(macOS)
    @MainActor
    private func startMacCloudControlPlane(accessToken: String) {
        let cloud = TravisCloudControlPlane.shared
        let bridge = TravisDeviceBridgeService.shared

        // Ensure a previous loop cannot survive a re-authentication.
        cloud.stop()
        cloud.configure(accessToken: accessToken)

        cloud.startMacHeartbeat(
            deviceKey: bridge.localDeviceID.uuidString,
            displayName: ProcessInfo.processInfo.hostName,
            workerOnline: {
                AlwaysOnWorkerMonitor.shared.refresh()
                return AlwaysOnWorkerMonitor.shared.isHealthy
            },
            guiOnline: {
                true
            },
            lanOnline: {
                TravisDeviceBridgeService.shared.isConnected
            }
        )
    }
#endif
}
