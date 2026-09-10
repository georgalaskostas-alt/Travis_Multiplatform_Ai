import Foundation

@MainActor
enum AlwaysOnIntelligenceBootstrap {
    private static let marketJobID = UUID(uuidString: "A1100000-0000-4000-8000-000000000001")!
    private static let paperJobID  = UUID(uuidString: "A1100000-0000-4000-8000-000000000002")!
    private static let auditJobID  = UUID(uuidString: "A1100000-0000-4000-8000-000000000003")!

    static func provision(monitor: AlwaysOnWorkerMonitor = .shared) {
        monitor.refresh()
        guard (monitor.snapshot?.version ?? 0) >= 9 else { return }
        let existing = Set(monitor.serviceJobs.map(\.id))
        do {
            if !existing.contains(marketJobID) {
                try monitor.enqueueCreateJob(
                    id: marketJobID,
                    title: "TRAVIS Crypto Market Intelligence",
                    kind: "marketScan",
                    payload: ["assets":["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"],"interval":"1h"],
                    cadenceSeconds: 300
                )
            }
            if !existing.contains(paperJobID) {
                try monitor.enqueueCreateJob(
                    id: paperJobID,
                    title: "TRAVIS Autonomous PAPER Strategy",
                    kind: "tradingPaper",
                    payload: [
                        "assets":["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"],
                        "interval":"1h",
                        "riskPercent":0.005,
                        "maxOpenPositions":3,
                        "maxDailyLoss":500.0,
                        "maxPositionNotional":2000.0,
                        "stopATRMultiple":1.8,
                        "takeProfitATRMultiple":2.7,
                        "minTrendScore":2.4,
                        "startingBalance":10000.0
                    ],
                    cadenceSeconds: 300
                )
            }
            if let root = developmentRepositoryRoot(), !existing.contains(auditJobID) {
                try monitor.enqueueCreateJob(
                    id: auditJobID,
                    title: "TRAVIS Continuous Self-Audit",
                    kind: "repositoryAudit",
                    payload: ["path":root.path],
                    cadenceSeconds: 21_600
                )
            }
        } catch {
            // Bootstrap is opportunistic; runtime health UI exposes worker failures.
        }
    }

    private static func developmentRepositoryRoot() -> URL? {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            if fm.fileExists(atPath: candidate.appendingPathComponent(".git").path),
               fm.fileExists(atPath: candidate.appendingPathComponent("Travis_Multiplatform_Ai").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
