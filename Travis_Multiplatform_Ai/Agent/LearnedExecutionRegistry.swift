import Foundation

/// Read-only projection of verified experience used to guide future execution
/// before any external AI reasoning is needed. It never executes old output and
/// never bypasses approval or verification. It only supplies a compact proven
/// precedent to the capability that is already going to execute the new step.
final class LearnedExecutionRegistry: @unchecked Sendable {
    static let shared = LearnedExecutionRegistry()

    struct ExampleSignature: Hashable {
        let capabilityId: String
        let instruction: String
        let verifiedResult: String
        let instructionTerms: Set<String>
        let projectId: UUID?
    }

    struct Guidance: Hashable {
        let confidence: Double
        let priorInstruction: String
        let priorVerifiedResult: String
        let sameProject: Bool
    }

    private let lock = NSLock()
    private var examplesByCapability: [String: [ExampleSignature]] = [:]
    private var _hits = 0
    private var _misses = 0

    private init() {}

    func rebuild(from examples: [VerifiedLearningStore.Example]) {
        let projected = examples.map { example in
            ExampleSignature(
                capabilityId: example.capabilityId,
                instruction: String(example.instruction.prefix(6000)),
                verifiedResult: String(example.verifiedResult.prefix(8000)),
                instructionTerms: Self.terms(example.title + " " + example.instruction),
                projectId: example.projectId
            )
        }
        let grouped = Dictionary(grouping: projected, by: \.capabilityId)
        lock.lock()
        examplesByCapability = grouped
        lock.unlock()
    }

    func guidance(
        instruction: String,
        capabilityId: String,
        projectId: UUID?,
        minimumConfidence: Double = 0.82
    ) -> Guidance? {
        guard Self.allowedCapabilities.contains(capabilityId) else {
            recordMiss(); return nil
        }

        let queryTerms = Self.terms(instruction)
        guard queryTerms.count >= 3 else { recordMiss(); return nil }

        lock.lock()
        let candidates = examplesByCapability[capabilityId] ?? []
        lock.unlock()

        var best: Guidance?
        for candidate in candidates {
            let overlap = queryTerms.intersection(candidate.instructionTerms)
            guard !overlap.isEmpty else { continue }
            let queryCoverage = Double(overlap.count) / Double(queryTerms.count)
            let candidateCoverage = candidate.instructionTerms.isEmpty ? 0 : Double(overlap.count) / Double(candidate.instructionTerms.count)
            let sameProject = projectId != nil && candidate.projectId == projectId
            let score = min(1, queryCoverage * 0.72 + candidateCoverage * 0.18 + (sameProject ? 0.10 : 0))
            guard score >= minimumConfidence else { continue }

            let proposed = Guidance(
                confidence: score,
                priorInstruction: candidate.instruction,
                priorVerifiedResult: candidate.verifiedResult,
                sameProject: sameProject
            )
            if best == nil || proposed.confidence > best!.confidence { best = proposed }
        }

        if let best { recordHit(); return best }
        recordMiss(); return nil
    }

    var hits: Int { lock.lock(); defer { lock.unlock() }; return _hits }
    var misses: Int { lock.lock(); defer { lock.unlock() }; return _misses }

    private func recordHit() { lock.lock(); _hits += 1; lock.unlock() }
    private func recordMiss() { lock.lock(); _misses += 1; lock.unlock() }

    /// Keep learned execution conservative. These capabilities are local and
    /// bounded; write/network/shell capabilities remain excluded here.
    private static let allowedCapabilities: Set<String> = [
        "local_file_search",
        "local_directory_analysis",
        "local_documents",
        "local_text_transform",
        "local_data",
        "local_productivity",
        "local_batch_text",
        "repository_context"
    ]

    private static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "this", "that", "with", "from", "into", "then", "when", "where", "what", "have", "will", "should", "using", "make", "create", "check", "please",
            "και", "που", "την", "τον", "των", "στο", "στη", "στην", "απο", "για", "με", "να", "το", "τα", "της", "του", "ενα", "μια", "πως", "οταν"
        ]
        return Set(text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }
}
