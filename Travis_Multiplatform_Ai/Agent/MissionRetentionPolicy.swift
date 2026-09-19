import Foundation

struct MissionRetentionPolicy {
    var maximumFinishedTasks = 200
    var maximumAgeDays = 30

    func pruned(_ tasks: [AgentTask], now: Date = Date()) -> [AgentTask] {
        let activeKeys: Set<String> = ["pending", "planning", "running", "waitingforapproval", "waitingfordependency", "paused"]
        let active = tasks.filter { activeKeys.contains(normalize($0.status.rawValue)) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -maximumAgeDays, to: now) ?? .distantPast
        let finished = tasks.filter { !activeKeys.contains(normalize($0.status.rawValue)) && $0.updatedAt >= cutoff }.sorted { $0.updatedAt > $1.updatedAt }
        return active + Array(finished.prefix(maximumFinishedTasks))
    }

    private func normalize(_ value: String) -> String { value.lowercased().filter { $0.isLetter } }
}
