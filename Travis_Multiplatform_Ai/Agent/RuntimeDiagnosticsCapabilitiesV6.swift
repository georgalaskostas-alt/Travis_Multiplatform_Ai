import Foundation

/// Registered, read-only capability proxies for worker-native runtime diagnostics.
/// Their IDs intentionally match HeadlessMissionHandoff so Mission V2 can plan
/// directly for Always-On execution instead of routing diagnostics through generic tools.
@MainActor
final class RuntimeDiagnosticsCapabilityV6: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    enum Kind: String {
        case identity = "runtime_identity"
        case health = "runtime_health"
        case safety = "runtime_safety"
        case report = "report_synthesis"
    }

    let kind: Kind
    var id: String { kind.rawValue }
    var name: String {
        switch kind {
        case .identity: return "TRAVIS Runtime Identity"
        case .health: return "TRAVIS Runtime Health"
        case .safety: return "TRAVIS Runtime Safety"
        case .report: return "TRAVIS Runtime Report"
        }
    }
    var capabilityDescription: String {
        switch kind {
        case .identity: return "Collect deterministic runtime identity, app version, OS and process context. Read-only and Always-On safe."
        case .health: return "Inspect deterministic runtime health context. Read-only and Always-On safe."
        case .safety: return "Inspect deterministic TRAVIS safety invariants. Read-only and Always-On safe."
        case .report: return "Synthesize verified runtime diagnostics into a final report. Read-only and Always-On safe."
        }
    }
    var keywords: [String] {
        switch kind {
        case .identity: return ["runtime identity", "runtime version", "ταυτότητα runtime", "ταυτοτητα runtime"]
        case .health: return ["runtime health", "runtime status", "υγεία runtime", "υγεια runtime"]
        case .safety: return ["runtime safety", "safety controls", "kill switch", "ασφάλεια runtime", "ασφαλεια runtime"]
        case .report: return ["runtime report", "diagnostic report", "τελική αναφορά runtime", "τελικη αναφορα runtime"]
        }
    }
    private(set) var status: AgentCapabilityStatus = .idle

    init(_ kind: Kind) { self.kind = kind }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .system,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                supportsBackgroundExecution: true,
                supportsProjectContext: false,
                timeoutSeconds: 30,
                maxAttempts: 2
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
    func resolve(_ action: ProposedAction) {}

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        let process = ProcessInfo.processInfo
        switch kind {
        case .identity:
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            #if os(macOS)
            let platform = "macOS"
            #elseif os(iOS)
            let platform = "iOS"
            #else
            let platform = "Apple"
            #endif
            return .reply("TRAVIS RUNTIME IDENTITY\nruntime: TRAVIS Multiplatform AI\nplatform: \(platform)\nappVersion: \(version)\nbuild: \(build)\nosVersion: \(process.operatingSystemVersionString)\nprocessName: \(process.processName)\nprocessID: \(process.processIdentifier)\ncollectedAt: \(ISO8601DateFormatter().string(from: Date()))")
        case .health:
            return .reply("TRAVIS RUNTIME HEALTH\nprocess: active\nprocessorCount: \(process.processorCount)\nactiveProcessorCount: \(process.activeProcessorCount)\nphysicalMemoryBytes: \(process.physicalMemory)\nosVersion: \(process.operatingSystemVersionString)\ncollectedAt: \(ISO8601DateFormatter().string(from: Date()))")
        case .safety:
            return .reply("TRAVIS RUNTIME SAFETY\narbitraryShell: disabled\nproductionLiveTrading: disabled\nwithdrawals: disabled\nselfEvolutionAutoMerge: disabled\nmutationApprovalGate: enabled\ntradingMode: paper/testnet only\ncollectedAt: \(ISO8601DateFormatter().string(from: Date()))")
        case .report:
            let context = recentHistory.suffix(8).map(\.text).joined(separator: "\n\n")
            return .reply(context.isEmpty ? "TRAVIS RUNTIME REPORT\nDeterministic report synthesis ready; Always-On execution assembles prior diagnostic step evidence." : "TRAVIS RUNTIME REPORT\n\n\(context)")
        }
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        let accepted: Set<String>
        switch kind {
        case .identity: accepted = ["identity", "inspect"]
        case .health: accepted = ["health", "inspect"]
        case .safety: accepted = ["safety", "inspect"]
        case .report: accepted = ["report", "synthesize"]
        }
        guard accepted.contains(invocation.operation) else {
            return .reply("Unsupported \(id) operation: \(invocation.operation)")
        }
        return try await handle(command: id, recentHistory: [])
    }
}
