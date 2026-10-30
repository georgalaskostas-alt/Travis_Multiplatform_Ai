#if os(macOS)
import SwiftUI

struct TravisPremiumHistoryView: View {
    @Bindable var appState: TRAVISAppState
    private let cyan = Color(red: 0.04, green: 0.82, blue: 1)
    private let navy = Color(red: 0.001, green: 0.018, blue: 0.072)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONVERSATION ARCHIVE").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1.1)
                    Text("TRAVIS MEMORY CHANNELS").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(cyan)
                }
                Spacer()
                Text("\(appState.pastSessions.count) SESSIONS").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(LinearGradient(colors: [.white.opacity(0.04), navy.opacity(0.82)], startPoint: .top, endPoint: .bottom))

            Rectangle().fill(LinearGradient(colors: [.clear, cyan.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if appState.pastSessions.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(cyan.opacity(0.7))
                            Text("NO ARCHIVED CONVERSATIONS").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        }.padding(.top, 70)
                    }
                    ForEach(appState.pastSessions) { session in
                        Button {
                            appState.viewSession(session.id)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9).fill(cyan.opacity(0.07)).frame(width: 42, height: 42)
                                    RoundedRectangle(cornerRadius: 9).stroke(cyan.opacity(0.30), lineWidth: 1).frame(width: 42, height: 42)
                                    Image(systemName: "message.fill").foregroundStyle(cyan)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.preview.isEmpty ? "Conversation" : session.preview)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(2)
                                    HStack(spacing: 10) {
                                        Text(session.startedAt, style: .date)
                                        Text(session.startedAt, style: .time)
                                        Text("\(session.messages.count) MSG")
                                    }.font(.system(size: 7, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(cyan)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.white.opacity(0.045), cyan.opacity(0.025), Color.black.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(cyan.opacity(0.22), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
        }
        .background(LinearGradient(colors: [Color(red:0.002,green:0.014,blue:0.052), Color(red:0.002,green:0.027,blue:0.090), Color.black.opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
#endif
