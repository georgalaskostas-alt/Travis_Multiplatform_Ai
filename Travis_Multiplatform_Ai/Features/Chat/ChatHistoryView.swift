import SwiftUI

struct ChatHistoryView: View {
    @Bindable var appState: TRAVISAppState

    var body: some View {
        Group {
            if appState.pastSessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Δεν υπάρχει ακόμα παλαιότερη συνομιλία.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.pastSessions) { session in
                    Button {
                        appState.viewSession(session.id)
                        appState.selectedSidebarItem = .chat
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.dateFormatter.string(from: session.startedAt))
                                .font(.headline)
                            if !session.preview.isEmpty {
                                Text(session.preview)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text("\(session.messages.count) μηνύματα")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            delete(session.id)
                        } label: {
                            Label("Διαγραφή", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(session.id)
                        } label: {
                            Label("Διαγραφή", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Ιστορικό")
    }

    private func delete(_ sessionId: UUID) {
        do {
            try ChatHistoryStore.deleteSession(sessionId)
            if appState.viewedSessionId == sessionId {
                appState.returnToCurrentSession()
            }
            appState.lastResponseSummary = "Η συνομιλία διαγράφηκε"
        } catch {
            appState.lastResponseSummary = "Αποτυχία διαγραφής: \(error.localizedDescription)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "el_GR")
        return formatter
    }()
}
