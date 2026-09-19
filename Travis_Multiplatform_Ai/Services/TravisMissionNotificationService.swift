import Foundation

#if os(iOS)
import UserNotifications
import UIKit

@MainActor
final class TravisMissionNotificationService {
    static let shared = TravisMissionNotificationService()

    private var requestedAuthorization = false
    private var emittedKeys = Set<String>()

    private init() {}

    func prepare() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(task: TravisBridgeTaskSnapshot) {
        let key = "\(task.id.uuidString)-\(task.status.lowercased())"
        guard emittedKeys.insert(key).inserted else { return }

        let normalized = task.status.lowercased().filter { $0.isLetter }
        guard normalized == "completed" || normalized == "failed" else { return }

        prepare()

        let completed = normalized == "completed"
        let detail = completed
            ? (task.finalReport ?? task.checkpoint ?? "Mission completed successfully.")
            : (task.failureReason ?? task.checkpoint ?? "Mission stopped with an error.")

        let content = UNMutableNotificationContent()
        content.title = completed ? "TRAVIS Mission Ready" : "TRAVIS Mission Needs Attention"
        content.subtitle = task.title
        content.body = String(detail.replacingOccurrences(of: "\n", with: " ").prefix(180))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "travis-mission-\(key)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
        UINotificationFeedbackGenerator().notificationOccurred(completed ? .success : .error)
    }
}
#endif
