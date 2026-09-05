import Foundation

@MainActor
enum AlwaysOnCommandRouter {
    static func handle(_ text:String, coordinator:AlwaysOnRuntimeCoordinator = .shared) -> String? {
        let command=text.trimmingCharacters(in:.whitespacesAndNewlines);let lower=command.lowercased();let worker=coordinator.worker;worker.refresh()
        if lower == "/alwayson-status" { let s=AlwaysOnRuntimeStatus.current();return "\(s.summary) · jobs \(s.jobsActive)/\(s.jobsTotal) · failures \(s.jobsFailed)" }
        if lower == "/alwayson-kill" { coordinator.emergencyStop();return "EMERGENCY STOP enabled." }
        if lower == "/alwayson-clear-kill" { coordinator.clearEmergencyStop();return "Emergency stop cleared." }
        if lower.hasPrefix("/alwayson-pause "),let job=worker.resolveServiceJob(String(command.dropFirst(16))){do{try worker.sendServiceJobCommand(action:"pause",jobID:job.id);return "Headless job pause requested."}catch{return "Headless pause failed: \(error.localizedDescription)"}}
        if lower.hasPrefix("/alwayson-resume "),let job=worker.resolveServiceJob(String(command.dropFirst(17))){do{try worker.sendServiceJobCommand(action:"resume",jobID:job.id);return "Headless job resume requested."}catch{return "Headless resume failed: \(error.localizedDescription)"}}
        if lower.hasPrefix("/alwayson-delete "),let job=worker.resolveServiceJob(String(command.dropFirst(17))){do{try worker.sendServiceJobCommand(action:"delete",jobID:job.id);return "Headless job delete requested."}catch{return "Headless delete failed: \(error.localizedDescription)"}}
        if lower.hasPrefix("/alwayson-retry "),let job=worker.resolveServiceJob(String(command.dropFirst(16))){do{try worker.sendServiceJobCommand(action:"retry",jobID:job.id);return "Headless job retry requested."}catch{return "Headless retry failed: \(error.localizedDescription)"}}
        if lower.hasPrefix("/alwayson-pause "),let id=resolveLegacy(String(command.dropFirst(16)),jobs:coordinator.engine.jobs){coordinator.engine.pause(id);return "Always-on job paused."}
        if lower.hasPrefix("/alwayson-resume "),let id=resolveLegacy(String(command.dropFirst(17)),jobs:coordinator.engine.jobs){coordinator.engine.resume(id);return "Always-on job resumed."}
        if lower.hasPrefix("/alwayson-delete "),let id=resolveLegacy(String(command.dropFirst(17)),jobs:coordinator.engine.jobs){coordinator.engine.delete(id);return "Always-on job deleted."}
        return nil
    }
    private static func resolveLegacy(_ raw:String,jobs:[AlwaysOnJob])->UUID?{let key=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if let id=UUID(uuidString:key){return id};let m=jobs.filter{$0.id.uuidString.lowercased().hasPrefix(key)};return m.count==1 ? m[0].id:nil}
}
