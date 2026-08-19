import Foundation

/// Thread-safe projection of verified learning examples used to avoid repeated
/// AI verification for strongly similar, low-risk local steps.
final class LearnedVerificationRegistry: @unchecked Sendable {
    static let shared = LearnedVerificationRegistry()

    struct ExampleSignature: Hashable {
        let capabilityId: String
        let instructionTerms: Set<String>
        let resultTerms: Set<String>
    }

    private let lock = NSLock()
    private var signaturesByCapability: [String: [ExampleSignature]] = [:]
    private var _localVerificationHits = 0
    private var _localVerificationMisses = 0

    private init() {}

    func rebuild(from examples: [VerifiedLearningStore.Example]) {
        let signatures = examples.map { example in
            ExampleSignature(
                capabilityId: example.capabilityId,
                instructionTerms: Self.terms(example.title + " " + example.instruction),
                resultTerms: Self.terms(String(example.verifiedResult.prefix(5000)))
            )
        }
        let grouped = Dictionary(grouping: signatures, by: \.capabilityId)
        lock.lock()
        signaturesByCapability = grouped
        lock.unlock()
    }

    func verify(step: PlanStep, capabilityResult: String) -> StepVerificationResult? {
        guard step.riskLevel == .low,
              !step.requiresApproval,
              let capabilityId = step.capabilityId,
              Self.allowedCapabilities.contains(capabilityId) else {
            recordMiss()
            return nil
        }

        let instructionTerms = Self.terms(step.title + " " + step.instructions)
        let resultTerms = Self.terms(String(capabilityResult.prefix(5000)))
        guard instructionTerms.count >= 2, resultTerms.count >= 2 else {
            recordMiss()
            return nil
        }

        lock.lock()
        let candidates = signaturesByCapability[capabilityId] ?? []
        lock.unlock()

        var bestScore = 0.0
        for candidate in candidates {
            let instructionOverlap = instructionTerms.intersection(candidate.instructionTerms)
            let resultOverlap = resultTerms.intersection(candidate.resultTerms)
            guard !instructionOverlap.isEmpty, !resultOverlap.isEmpty else { continue }

            let instructionCoverage = Double(instructionOverlap.count) / Double(instructionTerms.count)
            let resultCoverage = Double(resultOverlap.count) / Double(resultTerms.count)
            let score = instructionCoverage * 0.70 + resultCoverage * 0.30
            bestScore = max(bestScore, score)
        }

        guard bestScore >= 0.86 else {
            recordMiss()
            return nil
        }

        recordHit()
        return StepVerificationResult(
            verdict: .pass,
            confidence: min(0.99, bestScore),
            reason: "Matched a prior verified local execution pattern; AI verification skipped.",
            unmetCriteria: []
        )
    }

    var localVerificationHits: Int {
        lock.lock(); defer { lock.unlock() }
        return _localVerificationHits
    }

    var localVerificationMisses: Int {
        lock.lock(); defer { lock.unlock() }
        return _localVerificationMisses
    }

    private func recordHit() {
        lock.lock(); _localVerificationHits += 1; lock.unlock()
    }

    private func recordMiss() {
        lock.lock(); _localVerificationMisses += 1; lock.unlock()
    }

    private static let allowedCapabilities: Set<String> = [
        "local_file_search",
        "local_directory_analysis",
        "local_documents",
        "local_text_transform",
        "local_data",
        "local_productivity",
        "local_batch_text"
    ]

    private static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "this", "that", "with", "from", "into", "then", "when", "where", "what", "have", "will", "should", "using", "make", "create", "check", "please",
            "και", "που", "την", "τον", "των", "στο", "στη", "στην", "απο", "για", "με", "να", "το", "τα", "της", "του", "ενα", "μια", "πως", "οταν"
        ]
        return Set(
            text.lowercased()
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }
                .map(String.init)
                .filter { $0.count >= 3 && !stop.contains($0) }
        )
    }
}
