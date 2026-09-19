import Foundation

struct AlwaysOnRuntimeStatus: Equatable {
    var workerHealthy:Bool
    var workerPID:Int32?
    var killSwitchEnabled:Bool
    var jobsTotal:Int
    var jobsActive:Int
    var jobsFailed:Int
    var summary:String

    @MainActor static func current(engine:AlwaysOnRuntimeEngine = .shared, monitor:AlwaysOnWorkerMonitor = .shared) -> Self {
        let workerJobs=monitor.serviceJobs
        if !workerJobs.isEmpty || (monitor.snapshot?.version ?? 0) >= 4 {
            let active=workerJobs.filter{$0.enabled && !["paused","stopped"].contains($0.state.lowercased())}.count
            let failed=workerJobs.filter{$0.state.lowercased()=="failed"}.count
            return .init(workerHealthy:monitor.isHealthy,workerPID:monitor.snapshot?.pid,killSwitchEnabled:monitor.snapshot?.killSwitch ?? false,jobsTotal:workerJobs.count,jobsActive:active,jobsFailed:failed,summary:monitor.snapshot?.killSwitch == true ? "EMERGENCY STOP" : monitor.isHealthy ? "HEADLESS RUNTIME ONLINE" : "BACKGROUND WORKER OFFLINE")
        }
        let active:Set<AlwaysOnJobState>=[.scheduled,.running,.sleeping,.blocked]
        let failed=engine.jobs.filter{$0.state == .failed}.count
        return .init(workerHealthy:monitor.isHealthy,workerPID:monitor.snapshot?.pid,killSwitchEnabled:monitor.snapshot?.killSwitch ?? false,jobsTotal:engine.jobs.count,jobsActive:engine.jobs.filter{active.contains($0.state)&&$0.isEnabled}.count,jobsFailed:failed,summary:monitor.snapshot?.killSwitch == true ? "EMERGENCY STOP" : monitor.isHealthy ? "ALWAYS-ON RUNTIME ONLINE" : "BACKGROUND WORKER OFFLINE")
    }
}
