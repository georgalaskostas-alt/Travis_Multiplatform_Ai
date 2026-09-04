import Foundation

@MainActor
enum AlwaysOnCommandRouter {
    static func handle(_ text:String, coordinator:AlwaysOnRuntimeCoordinator = .shared) -> String? {
        let command=text.trimmingCharacters(in:.whitespacesAndNewlines);let lower=command.lowercased()
        if lower == "/alwayson-status" { let s=AlwaysOnRuntimeStatus.current();return "\(s.summary) · jobs \(s.jobsActive)/\(s.jobsTotal) · failures \(s.jobsFailed)" }
        if lower == "/alwayson-kill" { coordinator.emergencyStop();return "EMERGENCY STOP enabled. Always-on jobs paused." }
        if lower == "/alwayson-clear-kill" { coordinator.clearEmergencyStop();return "Emergency stop cleared. Jobs remain paused until explicitly resumed." }
        if lower.hasPrefix("/alwayson-pause "),let id=resolve(String(command.dropFirst(16)),jobs:coordinator.engine.jobs){coordinator.engine.pause(id);return "Always-on job paused."}
        if lower.hasPrefix("/alwayson-resume "),let id=resolve(String(command.dropFirst(17)),jobs:coordinator.engine.jobs){coordinator.engine.resume(id);return "Always-on job resumed."}
        if lower.hasPrefix("/alwayson-delete "),let id=resolve(String(command.dropFirst(17)),jobs:coordinator.engine.jobs){coordinator.engine.delete(id);return "Always-on job deleted."}
        return nil
    }
    private static func resolve(_ raw:String,jobs:[AlwaysOnJob])->UUID?{let key=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if let id=UUID(uuidString:key){return id};let m=jobs.filter{$0.id.uuidString.lowercased().hasPrefix(key)};return m.count==1 ? m[0].id:nil}
}
