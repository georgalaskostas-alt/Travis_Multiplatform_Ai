import Foundation

@MainActor
enum AlwaysOnIntelligenceBootstrap {
    private static let marketJobID=UUID(uuidString:"A1100000-0000-4000-8000-000000000001")!
    private static let paperJobID=UUID(uuidString:"A1100000-0000-4000-8000-000000000002")!
    private static let auditJobID=UUID(uuidString:"A1100000-0000-4000-8000-000000000003")!
    private static let testnetJobID=UUID(uuidString:"A1100000-0000-4000-8000-000000000004")!

    static func provision(monitor:AlwaysOnWorkerMonitor = .shared,persistence:PersistenceService = .shared){
        monitor.refresh();guard (monitor.snapshot?.version ?? 0)>=10 else{return};HeadlessTradingMandateBridge.synchronize(persistence:persistence);let existing=Set(monitor.serviceJobs.map(\.id))
        do{
            if !existing.contains(marketJobID){try monitor.enqueueCreateJob(id:marketJobID,title:"TRAVIS Crypto Market Intelligence",kind:"marketScan",payload:["assets":["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"],"interval":"1h"],cadenceSeconds:300)}
            if !existing.contains(paperJobID){try monitor.enqueueCreateJob(id:paperJobID,title:"TRAVIS Autonomous PAPER Strategy",kind:"tradingPaper",payload:["assets":["BTC","ETH","SOL","XRP","BNB","ADA","DOGE","LINK"],"interval":"1h","riskPercent":0.005,"maxOpenPositions":3,"maxDailyLoss":500.0,"maxPositionNotional":2000.0,"stopATRMultiple":1.8,"takeProfitATRMultiple":2.7,"minTrendScore":2.4,"startingBalance":10000.0],cadenceSeconds:300)}
            // Continuous self-review must not burn cloud tokens while idle. The recurring audit is deterministic/read-only.
            // AI code analysis is escalated explicitly by Mission V2/SelfImprovement only when findings justify it.
            if let root=developmentRepositoryRoot(),!existing.contains(auditJobID){try monitor.enqueueCreateJob(id:auditJobID,title:"TRAVIS Continuous Zero-Token Self Audit",kind:"repositoryAudit",payload:["path":root.path],cadenceSeconds:86_400)}
            let mandates=persistence.standingPermissions(withKeyPrefix:"trading_testnet_").filter(\.granted),assets=mandates.compactMap{p->String? in let prefix="trading_testnet_";guard p.key.hasPrefix(prefix)else{return nil};let a=String(p.key.dropFirst(prefix.count)).uppercased();return a.isEmpty ? nil:a},hasCredentials=KeychainService.shared.binanceTestnetAPIKey?.isEmpty == false && KeychainService.shared.binanceTestnetAPISecret?.isEmpty == false
            if !assets.isEmpty,hasCredentials,!existing.contains(testnetJobID){try monitor.enqueueCreateJob(id:testnetJobID,title:"TRAVIS Authorized TESTNET Strategy",kind:"tradingTestnet",payload:["authorized":true,"assets":Array(Set(assets)).sorted(),"interval":"1h","maxOpenPositions":2,"maxPositionNotional":250.0,"minTrendScore":2.8],cadenceSeconds:300)}
        }catch{}
    }
    private static func developmentRepositoryRoot()->URL?{var candidate=URL(fileURLWithPath:#filePath).deletingLastPathComponent();let fm=FileManager.default;for _ in 0..<8{if fm.fileExists(atPath:candidate.appendingPathComponent(".git").path),fm.fileExists(atPath:candidate.appendingPathComponent("Travis_Multiplatform_Ai").path){return candidate};candidate.deleteLastPathComponent()};return nil}
}
