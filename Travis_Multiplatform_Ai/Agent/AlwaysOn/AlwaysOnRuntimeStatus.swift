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
        let active:Set<AlwaysOnJobState>=[.scheduled,.running,.sleeping,.blocked]
        let failed=engine.jobs.filter{$0.state == .failed}.count
        return .init(workerHealthy:monitor.isHealthy,workerPID:monitor.snapshot?.pid,killSwitchEnabled:monitor.snapshot?.killSwitch ?? false,jobsTotal:engine.jobs.count,jobsActive:engine.jobs.filter{active.contains($0.state)&&$0.isEnabled}.count,jobsFailed:failed,summary:monitor.snapshot?.killSwitch == true ? "EMERGENCY STOP" : monitor.isHealthy ? "ALWAYS-ON RUNTIME ONLINE" : "BACKGROUND WORKER OFFLINE")
    }
}
