import Foundation

enum AlwaysOnRecoveryPolicy {
    static func recover(_ jobs:[AlwaysOnJob], now:Date=Date()) -> [AlwaysOnJob] {
        jobs.map { original in
            var job=original
            switch job.state {
            case .running:
                job.state = .scheduled; job.nextRunAt=now; job.lastError="Recovered after runtime restart"
            case .failed:
                if job.isEnabled && (job.nextRunAt == nil || job.nextRunAt! <= now) { job.state = .scheduled; job.nextRunAt=now }
            default: break
            }
            job.updatedAt=now
            return job
        }
    }
}
