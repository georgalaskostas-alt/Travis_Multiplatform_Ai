import Foundation
import Observation

/// TRAVIS V6 cognitive policy: use the cheapest reliable intelligence that can
/// complete AND verify a task. This layer does not execute side effects; it
/// decides how much context/intelligence should be purchased and records why.
@MainActor
@Observable
final class CognitiveCoreV6 {
    static let shared = CognitiveCoreV6()

    enum Route: String, Codable, CaseIterable {
        case deterministicLocal
        case learnedLocal
        case localModel
        case cloudEconomy
        case cloudBalanced
        case cloudFrontier
    }

    struct Decision: Identifiable, Codable, Hashable {
        let id: UUID
        let at: Date
        let route: Route
        let workload: AIWorkloadClass
        let confidence: Double
        let rationale: String
        let capabilityId: String?
        let taskId: UUID?
        let projectId: UUID?
        let estimatedAvoidedCloudCall: Bool
    }

    struct ContextPacket: Hashable {
        let prompt: String
        let learnedEvidenceIncluded: Bool
        let evidenceCharacters: Int
        let decision: Decision
    }

    private(set) var decisions: [Decision] = []
    private(set) var localAvoidedCloudCalls = 0
    private(set) var learnedEvidenceReuses = 0
    private let maxDecisionHistory = 2_000
    private let evidenceCharacterBudget = 2_400

    private init() {}

    /// Builds a deliberately small context packet. We never attach the entire
    /// memory store to a cloud prompt: only a strongly matching verified local
    /// precedent can be injected, and it is capped to a few KB.
    func prepareRemotePrompt(_ prompt: String, context: AIInvocationContext) -> ContextPacket {
        let workload = context.workload
        var enriched = prompt
        var included = false
        var evidenceChars = 0
        var confidence = 0.55
        var rationale = "Novel request requires model reasoning."

        if let capabilityId = context.capabilityId,
           let guidance = LearnedExecutionRegistry.shared.guidance(
                instruction: prompt,
                capabilityId: capabilityId,
                projectId: context.projectId,
                minimumConfidence: 0.90
           ) {
            let evidence = """

            VERIFIED LOCAL PRECEDENT (procedure evidence only; re-check current facts):
            prior instruction: \(String(guidance.priorInstruction.prefix(900)))
            prior verified result: \(String(guidance.priorVerifiedResult.prefix(1_200)))
            similarity confidence: \(Int(guidance.confidence * 100))%
            """
            let bounded = String(evidence.prefix(evidenceCharacterBudget))
            enriched += bounded
            included = true
            evidenceChars = bounded.count
            confidence = guidance.confidence
            rationale = "A highly similar verified precedent was retrieved locally; only compact evidence is sent to reduce tokens."
            learnedEvidenceReuses += 1
        }

        let route = routeFor(workload: workload)
        let decision = Decision(
            id: UUID(), at: Date(), route: route, workload: workload,
            confidence: confidence, rationale: rationale,
            capabilityId: context.capabilityId, taskId: context.taskId,
            projectId: context.projectId, estimatedAvoidedCloudCall: false
        )
        record(decision)
        return ContextPacket(prompt: enriched, learnedEvidenceIncluded: included, evidenceCharacters: evidenceChars, decision: decision)
    }

    func recordLocalResolution(capabilityId: String?, taskId: UUID? = nil, projectId: UUID? = nil, learned: Bool = false, confidence: Double = 1.0, rationale: String = "Resolved locally without purchasing cloud inference.") {
        localAvoidedCloudCalls += 1
        if learned { learnedEvidenceReuses += 1 }
        record(Decision(id:UUID(),at:Date(),route:learned ? .learnedLocal:.deterministicLocal,workload:.deterministic,confidence:min(1,max(0,confidence)),rationale:rationale,capabilityId:capabilityId,taskId:taskId,projectId:projectId,estimatedAvoidedCloudCall:true))
    }

    func diagnosticReport() -> String {
        TravisLearningService.shared.refresh()
        let learning = TravisLearningService.shared
        let recent = decisions.suffix(250)
        let routes = Dictionary(grouping: recent, by: \.route).mapValues(\.count)
        let routeRows = Route.allCases.map { "\($0.rawValue): \(routes[$0, default: 0])" }.joined(separator: "\n")
        let usage = AIUsageLedger.shared.summary(since: Calendar.current.startOfDay(for: Date()))
        return """
        TRAVIS COGNITIVE CORE V6

        POLICY
        local deterministic → verified learned skill → local model → Luna economy → Terra balanced → Sol frontier
        Escalate only for novelty, uncertainty, verification or risk.

        LOCAL INTELLIGENCE
        avoided cloud calls: \(localAvoidedCloudCalls)
        verified evidence reuses: \(learnedEvidenceReuses)
        verified examples: \(VerifiedLearningStore.shared.examples.count)
        learned routes: \(learning.learnedRoutes)
        learning confidence: \(Int(learning.confidence * 100))%

        TODAY CLOUD USAGE
        requests: \(usage.requests)
        input tokens: \(usage.inputTokens)
        cached input tokens: \(usage.cachedInputTokens)
        output tokens: \(usage.outputTokens)
        reasoning tokens: \(usage.reasoningTokens)
        estimated spend: $\(String(format: "%.4f", usage.estimatedCostUSD))

        RECENT ROUTING
        \(routeRows)

        MEMORY RULE
        Never send full memory/history by default. Retrieve only strongly relevant verified evidence within a bounded context budget.
        """
    }

    private func routeFor(workload: AIWorkloadClass) -> Route {
        switch workload {
        case .deterministic: return .deterministicLocal
        case .classification, .routine: return .cloudEconomy
        case .complex, .verification, .webResearch: return .cloudBalanced
        case .frontier: return .cloudFrontier
        }
    }

    private func record(_ decision: Decision) {
        decisions.append(decision)
        if decisions.count > maxDecisionHistory { decisions.removeFirst(decisions.count - maxDecisionHistory) }
    }
}

/// Durable post-mission reflection. Only verified/terminal outcomes are retained.
/// Reflections are short on purpose: this is procedural memory, not a transcript archive.
@MainActor
@Observable
final class CognitiveReflectionStore {
    static let shared = CognitiveReflectionStore()

    struct Reflection: Identifiable, Codable, Hashable {
        let id: UUID
        let createdAt: Date
        let taskId: UUID
        let projectId: UUID?
        let outcome: String
        let goalFingerprint: String
        let lesson: String
        let failedCapabilities: [String]
        let successfulCapabilities: [String]
        let planVersion: Int
    }
    private struct Snapshot: Codable { var version: Int; var reflections: [Reflection] }

    private(set) var reflections: [Reflection] = []
    private let fileURL: URL
    private let maxReflections = 5_000

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cognitive-reflections-v1.json")
        if let data = try? Data(contentsOf: fileURL), let snap = try? JSONDecoder().decode(Snapshot.self, from: data), snap.version == 1 { reflections = snap.reflections }
    }

    func ingest(_ task: AgentTask, projectId: UUID?) {
        guard [.completed, .failed, .cancelled].contains(task.status) else { return }
        guard !reflections.contains(where: { $0.taskId == task.id && $0.planVersion == task.plan.version }) else { return }
        let successes = task.plan.steps.filter { $0.status == .completed }.compactMap(\.capabilityId)
        let failures = task.plan.steps.filter { $0.status == .failed }.compactMap(\.capabilityId)
        let lesson: String
        if task.status == .completed {
            lesson = "Plan v\(task.plan.version) completed with \(successes.count) verified capability steps. Reuse matching verified procedures, but re-check current-state evidence."
        } else {
            let reason = task.failureReason ?? task.plan.steps.first(where: {$0.status == .failed})?.lastError ?? "terminal without verified completion"
            lesson = "Plan v\(task.plan.version) did not complete. Avoid repeating the same failing route without new evidence: \(String(reason.prefix(900)))"
        }
        reflections.append(Reflection(id:UUID(),createdAt:Date(),taskId:task.id,projectId:projectId,outcome:task.status.rawValue,goalFingerprint:Self.fingerprint(task.goal),lesson:lesson,failedCapabilities:Array(Set(failures)).sorted(),successfulCapabilities:Array(Set(successes)).sorted(),planVersion:task.plan.version))
        if reflections.count > maxReflections { reflections.removeFirst(reflections.count-maxReflections) }
        persist()
    }

    func relevant(to goal: String, projectId: UUID?, limit: Int = 4) -> [Reflection] {
        let q = Set(Self.terms(goal)); guard !q.isEmpty else { return [] }
        return reflections.compactMap { r -> (Reflection, Double)? in
            let t = Set(Self.terms(r.goalFingerprint)); let overlap = q.intersection(t)
            guard !overlap.isEmpty else { return nil }
            let score = Double(overlap.count) / Double(max(1, q.union(t).count)) + ((projectId != nil && projectId == r.projectId) ? 0.20 : 0)
            return score >= 0.18 ? (r, score) : nil
        }.sorted {$0.1 > $1.1}.prefix(max(1,min(limit,8))).map(\.0)
    }

    func compactContext(goal: String, projectId: UUID?) -> String {
        let rows = relevant(to:goal,projectId:projectId).map { "- [\($0.outcome)] \($0.lesson)" }
        return rows.isEmpty ? "" : "PREVIOUS VERIFIED REFLECTIONS\n" + rows.joined(separator:"\n")
    }

    private func persist() { if let data = try? JSONEncoder().encode(Snapshot(version:1,reflections:reflections)) { try? data.write(to:fileURL,options:.atomic) } }
    private static func fingerprint(_ text:String)->String { String(text.lowercased().prefix(1_500)) }
    private static func terms(_ text:String)->[String] { text.lowercased().folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split{!$0.isLetter && !$0.isNumber}.map(String.init).filter{$0.count>=3} }
}
