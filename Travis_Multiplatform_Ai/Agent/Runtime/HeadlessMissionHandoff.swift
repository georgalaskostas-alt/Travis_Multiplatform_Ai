import Foundation

/// Bridges a planned Mission V2 task into the independent LaunchAgent worker.
/// Only explicitly mapped, read-only/background-safe capabilities are exported.
/// The worker remains the authority after a successful handoff.
@MainActor
enum HeadlessMissionHandoff {
    struct ExportResult: Equatable {
        let jobID: UUID
        let exportedSteps: Int
    }

    enum HandoffError: LocalizedError {
        case noSteps
        case unsupportedStep(String)
        case approvalRequired(String)
        case foregroundOnly(String)
        case missingArguments(String)
        case workerUnavailable
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .noSteps: return "Mission has no executable steps."
            case .unsupportedStep(let value): return "Step cannot run headlessly: \(value)"
            case .approvalRequired(let value): return "Approval-gated step stays in the GUI runtime: \(value)"
            case .foregroundOnly(let value): return "Foreground-only step stays in the GUI runtime: \(value)"
            case .missingArguments(let value): return "Headless step is missing deterministic arguments: \(value)"
            case .workerUnavailable: return "Headless worker is offline."
            case .writeFailed(let value): return "Headless handoff failed: \(value)"
            }
        }
    }

    private struct ServiceDocument: Codable { var version: Int; var jobs: [ServiceJob] }
    private struct ServiceJob: Codable {
        var id: String; var title: String; var kind: String; var state: String
        var createdAt: TimeInterval; var updatedAt: TimeInterval; var nextRunAt: TimeInterval?
        var cadenceSeconds: Double?; var payload: Payload; var enabled: Bool; var failures: Int
        var recoveryCount: Int; var lastError: String?; var lease: String?; var checkpoint: String?
    }
    private struct Payload: Codable { var goal: String; var sourceTaskID: String; var sourcePlanVersion: Int; var plan: [HeadlessStep] }
    private struct HeadlessStep: Codable { var order: Int; var title: String; var capability: String; var arguments: [String:String]? }

    static func eligibility(task: AgentTask) -> Result<[String], HandoffError> {
        guard !task.plan.steps.isEmpty else { return .failure(.noSteps) }
        var mapped: [String] = []
        for step in task.plan.steps.sorted(by: { $0.order < $1.order }) where step.status != .completed && step.status != .skipped {
            if step.requiresApproval { return .failure(.approvalRequired(step.title)) }
            if !step.canRunInBackground { return .failure(.foregroundOnly(step.title)) }
            guard let capability = mappedCapability(step.capabilityId) else { return .failure(.unsupportedStep(step.capabilityId ?? step.title)) }
            mapped.append(capability)
        }
        return mapped.isEmpty ? .failure(.noSteps) : .success(mapped)
    }

    static func export(task: AgentTask, requireHealthyWorker: Bool = true) throws -> ExportResult {
        if requireHealthyWorker {
            AlwaysOnWorkerMonitor.shared.refresh()
            guard AlwaysOnWorkerMonitor.shared.isHealthy else { throw HandoffError.workerUnavailable }
        }
        let remaining = task.plan.steps.sorted(by: { $0.order < $1.order }).filter { $0.status != .completed && $0.status != .skipped }
        _ = try eligibility(task: task).get()
        var steps: [HeadlessStep] = []
        for step in remaining {
            guard let capability = mappedCapability(step.capabilityId) else { throw HandoffError.unsupportedStep(step.capabilityId ?? step.title) }
            let args = arguments(for: step, capability: capability)
            if ["repository.snapshot", "filesystem.inventory", "network.http_probe"].contains(capability), args == nil {
                throw HandoffError.missingArguments(step.title)
            }
            steps.append(.init(order: step.order, title: step.title, capability: capability, arguments: args))
        }
        let jobID = UUID(); let now = Date().timeIntervalSince1970
        let job = ServiceJob(id: jobID.uuidString, title: "Mission V2 · \(task.title)", kind: "headlessMission", state: "scheduled", createdAt: now, updatedAt: now, nextRunAt: now, cadenceSeconds: nil, payload: .init(goal: task.goal, sourceTaskID: task.id.uuidString, sourcePlanVersion: task.plan.version, plan: steps), enabled: true, failures: 0, recoveryCount: 0, lastError: nil, lease: nil, checkpoint: nil)
        do { try append(job: job) } catch { throw HandoffError.writeFailed(error.localizedDescription) }
        return .init(jobID: jobID, exportedSteps: steps.count)
    }

    private static func mappedCapability(_ id: String?) -> String? {
        switch id {
        case "repository_context": return "repository.snapshot"
        case "runtime_health", "system_scan": return "runtime.health"
        case "runtime_identity": return "runtime.identity"
        case "runtime_safety": return "runtime.safety"
        case "filesystem_inventory": return "filesystem.inventory"
        case "http_probe", "network_probe": return "network.http_probe"
        case "report_synthesis": return "report.synthesize"
        default: return nil
        }
    }

    /// Extract deterministic arguments only when they are explicit in the planner instructions.
    /// This intentionally refuses to invent paths/URLs.
    private static func arguments(for step: PlanStep, capability: String) -> [String:String]? {
        let text = step.instructions
        if capability == "repository.snapshot" || capability == "filesystem.inventory" {
            guard let path = firstValue(prefixes: ["path=", "repoPath=", "rootPath="], in: text) else { return nil }
            return ["path": path]
        }
        if capability == "network.http_probe" {
            guard let url = firstValue(prefixes: ["url="], in: text) else { return nil }
            return ["url": url]
        }
        return nil
    }

    private static func firstValue(prefixes: [String], in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
            let value = String(token)
            for prefix in prefixes where value.hasPrefix(prefix) {
                let result = String(value.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !result.isEmpty { return result }
            }
        }
        return nil
    }

    private static func append(job: ServiceJob) throws {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("TRAVIS/AlwaysOn", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("service-jobs-v1.json")
        var document: ServiceDocument
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ServiceDocument.self, from: data) { document = decoded }
        else { document = ServiceDocument(version: 4, jobs: []) }
        document.version = 4; document.jobs.append(job)
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }
}
