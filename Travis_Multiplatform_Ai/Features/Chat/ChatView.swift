import SwiftUI

struct ChatView: View {
    @Bindable var appState: TRAVISAppState
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.cyan.opacity(0.95),
                                    Color.blue.opacity(0.65),
                                    Color.blue.opacity(0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 140
                            )
                        )
                        .frame(width: 180, height: 180)
                        .blur(radius: 2)

                    Circle()
                        .stroke(Color.cyan.opacity(0.8), lineWidth: 2)
                        .frame(width: 220, height: 220)

                    Circle()
                        .stroke(Color.blue.opacity(0.45), lineWidth: 12)
                        .frame(width: 170, height: 170)

                    VStack(spacing: 8) {
                        Text(appState.assistantName.uppercased())
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(appState.currentDeviceState.title)
                            .font(.caption)
                            .foregroundStyle(.cyan.opacity(0.9))
                    }
                }

                Text(appState.lastResponseSummary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top)

            if !appState.chatMessages.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Μηνύματα")
                        .font(.headline)
                        .foregroundStyle(.white)

                    ForEach(appState.chatMessages.suffix(5)) { message in
                        HStack {
                            if message.role == .assistant {
                                Text(message.text)
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(Color.cyan.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Spacer(minLength: 24)
                            } else {
                                Spacer(minLength: 24)
                                Text(message.text)
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            if !appState.approvalGate.pendingActions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Προτεινόμενες Ενέργειες")
                        .font(.headline)
                        .foregroundStyle(.white)

                    ForEach(appState.approvalGate.pendingActions) { action in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(action.summary)
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)

                            Text(action.reasoning)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))

                            Text(action.expectedImpact)
                                .font(.caption)
                                .foregroundStyle(.cyan.opacity(0.85))

                            HStack {
                                Text("Ρίσκο: \(action.riskLevel.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))

                                Spacer()

                                Button("Reject") {
                                    appState.approvalGate.reject(action)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button("Approve") {
                                    appState.approvalGate.approve(action)
                                    if let text = action.payload {
                                        appState.saveGeneratedText(text)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Command Queue")
                    .font(.headline)
                    .foregroundStyle(.white)

                if appState.pendingCommands.isEmpty {
                    Text("Δεν υπάρχουν ακόμα εντολές.")
                        .foregroundStyle(.white.opacity(0.65))
                } else {
                    ForEach(appState.pendingCommands.prefix(5)) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.text)
                                .foregroundStyle(.white)
                            Text("\(command.source.rawValue) • \(command.status.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.cyan.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 12) {
                TextField("Δώσε εντολή στον Travis...", text: $draft)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)

                Button {
                    appState.sendCommand(draft, source: .manual)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                Button(appState.isListening ? "Stop Listening" : "Start Listening") {
                    appState.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("Demo Internet Query") {
                    appState.sendCommand("Βρες πληροφορίες από το internet", source: .voice)
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.black, Color.blue.opacity(0.45), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
