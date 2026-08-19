#if os(macOS)
import SwiftUI

struct TravisPremiumWorkspaceChatView: View {
    @Bindable var appState: TRAVISAppState
    @State private var draft = ""
    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)
    private let panel = Color(red: 0.004, green: 0.042, blue: 0.125)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(cyan.opacity(0.10)).frame(width: 36, height: 36)
                    Circle().stroke(cyan.opacity(0.75), lineWidth: 1.4).frame(width: 36, height: 36)
                    Image(systemName: "message.fill").foregroundStyle(cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRAVIS COMM LINK").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(1.1)
                    Text(appState.viewedSessionId == appState.currentSessionId ? "LIVE CONVERSATION" : "ARCHIVED CONVERSATION")
                        .font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(appState.viewedSessionId == appState.currentSessionId ? .green : .orange)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(appState.isBusy ? Color.orange : Color.green).frame(width: 6, height: 6).shadow(color: appState.isBusy ? .orange : .green, radius: 4)
                    Text(appState.isBusy ? "TRAVIS WORKING" : "TRAVIS READY").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                if appState.viewedSessionId != appState.currentSessionId {
                    Button("RETURN LIVE") { appState.returnToCurrentSession() }.buttonStyle(PremiumWorkspaceButton(tint: cyan))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(LinearGradient(colors: [.white.opacity(0.045), panel.opacity(0.72), navy.opacity(0.88)], startPoint: .top, endPoint: .bottom))

            Rectangle().fill(LinearGradient(colors: [.clear, cyan.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if appState.chatMessages.isEmpty {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(RadialGradient(colors: [cyan.opacity(0.24), .clear], center: .center, startRadius: 0, endRadius: 54)).frame(width: 110, height: 110)
                                    Circle().stroke(cyan.opacity(0.42), lineWidth: 1.3).frame(width: 74, height: 74)
                                    Text("T").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(.white).shadow(color: cyan, radius: 8)
                                }
                                Text("COMM CHANNEL READY").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(cyan)
                                Text("Δώσε εντολή ή ξεκίνα νέα αποστολή.").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 70)
                        }
                        ForEach(appState.chatMessages) { message in
                            messageRow(message).id(message.id)
                        }
                    }.padding(18)
                }
                .onChange(of: appState.chatMessages.count) { _, _ in
                    if let last = appState.chatMessages.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Rectangle().fill(LinearGradient(colors: [.clear, cyan.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.36))
                    RoundedRectangle(cornerRadius: 10).stroke(LinearGradient(colors: [.white.opacity(0.16), cyan.opacity(0.42), .blue.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1)
                    TextField("COMMAND TRAVIS...", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 14)
                        .onSubmit { send() }
                }.frame(height: 42)

                Button { appState.toggleListening() } label: {
                    Image(systemName: appState.isListening ? "waveform" : "mic.fill").frame(width: 38, height: 38)
                }.buttonStyle(PremiumWorkspaceIconButton(tint: appState.isListening ? .green : cyan))

                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .heavy)).frame(width: 38, height: 38)
                }.buttonStyle(PremiumWorkspaceIconButton(tint: cyan))
            }
            .padding(14)
            .background(LinearGradient(colors: [navy.opacity(0.82), panel.opacity(0.52)], startPoint: .top, endPoint: .bottom))
        }
        .background(LinearGradient(colors: [Color(red:0.002,green:0.014,blue:0.052), Color(red:0.002,green:0.028,blue:0.095), Color.black.opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .onAppear { if draft.isEmpty { draft = appState.chatInput; appState.chatInput = "" } }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatar("T", cyan)
                bubble(message, tint: cyan, alignment: .leading)
                Spacer(minLength: 70)
            } else {
                Spacer(minLength: 70)
                bubble(message, tint: .blue, alignment: .trailing)
                avatar("YOU", .blue)
            }
        }
    }

    private func avatar(_ text: String, _ tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.09)).frame(width: 36, height: 36)
            RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.55), lineWidth: 1).frame(width: 36, height: 36)
            Text(text).font(.system(size: text == "T" ? 15 : 7, weight: .heavy, design: .rounded)).foregroundStyle(tint)
        }
    }

    private func bubble(_ message: ChatMessage, tint: Color, alignment: Alignment) -> some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 5) {
            Text(message.role == .assistant ? "TRAVIS" : "OPERATOR").font(.system(size: 7, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(tint)
            Text(message.text).font(.system(size: 12, weight: .regular, design: .rounded)).textSelection(.enabled).frame(maxWidth: 650, alignment: alignment)
            Text(message.createdAt, style: .time).font(.system(size: 7, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.white.opacity(0.045), tint.opacity(0.055), Color.black.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.26), lineWidth: 1))
        .shadow(color: tint.opacity(0.05), radius: 7)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.sendCommand(text, source: .manual)
        draft = ""
    }
}

private struct PremiumWorkspaceButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.38), lineWidth: 1))
    }
}

private struct PremiumWorkspaceIconButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(configuration.isPressed ? 0.18 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.45), lineWidth: 1))
            .shadow(color: tint.opacity(0.10), radius: 5)
    }
}
#endif
