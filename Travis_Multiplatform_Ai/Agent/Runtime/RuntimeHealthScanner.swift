import Foundation

struct RuntimeHealthFinding: Identifiable, Codable, Equatable {
    enum Severity: String, Codable { case info, warning, critical }
    var id = UUID()
    var severity: Severity
    var title: String
    var detail: String
}

struct RuntimeHealthReport: Codable, Equatable {
    var generatedAt = Date()
    var findings: [RuntimeHealthFinding]
    var score: Int
    var summary: String
}

@MainActor
enum RuntimeHealthScanner {
    static func scan(appState: TRAVISAppState, bridge: TravisDeviceBridgeService = .shared) -> RuntimeHealthReport {
        var findings: [RuntimeHealthFinding] = []
        let tasks = appState.taskRuntime.tasks
        let activeStatuses: Set<AgentTaskStatus> = [.pending, .planning, .running, .waitingForApproval, .waitingForDependency, .paused]
        let active = tasks.filter { activeStatuses.contains($0.status) }
        let failed = tasks.filter { $0.status == .failed }
        let stalled = active.filter { Date().timeIntervalSince($0.updatedAt) > 60 * 30 }

        if stalled.isEmpty { findings.append(.init(severity: .info, title: "Runtime freshness", detail: "No active mission has been stale for more than 30 minutes.")) }
        else { findings.append(.init(severity: .warning, title: "Potentially stalled missions", detail: "\(stalled.count) active mission(s) have not updated for more than 30 minutes.")) }

        if failed.isEmpty { findings.append(.init(severity: .info, title: "Task failures", detail: "No failed runtime tasks are currently stored.")) }
        else { findings.append(.init(severity: .warning, title: "Stored failures", detail: "\(failed.count) failed task(s) remain available for diagnosis or retry.")) }

        #if os(iOS)
        if bridge.isConnected { findings.append(.init(severity: .info, title: "Mac bridge", detail: "Connected to \(bridge.connectedPeerName ?? "Mac TRAVIS").")) }
        else { findings.append(.init(severity: .warning, title: "Mac bridge", detail: "Mac TRAVIS is not connected; remote mission control is unavailable.")) }
        #endif

        let critical = findings.filter { $0.severity == .critical }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        let score = max(0, 100 - critical * 35 - warnings * 10)
        let summary = critical > 0 ? "Runtime requires attention" : warnings > 0 ? "Runtime operational with warnings" : "Runtime healthy"
        return RuntimeHealthReport(findings: findings, score: score, summary: summary)
    }
}
