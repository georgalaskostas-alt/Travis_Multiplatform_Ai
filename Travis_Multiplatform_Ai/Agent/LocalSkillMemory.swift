import Foundation
import Observation

/// Turns verified TRAVIS experience into locally searchable reusable skills.
/// This layer does not call an external AI model. It is deliberately simple,
/// deterministic and inspectable: verified examples are matched by words and
/// capability, then returned only when confidence is high enough.
@MainActor
@Observable
final class LocalSkillMemory {
    static let shared = LocalSkillMemory()

    struct Match: Hashable {
        let example: VerifiedLearningStore.Example
        let confidence: Double
        let matchedTerms: [String]
    }

    private(set) var localHits: Int = 0
    private(set) var localMisses: Int = 0

    private init() {}

    func bestMatch(
        instruction: String,
        capabilityId: String? = nil,
        projectId: UUID? = nil,
        minimumConfidence: Double = 0.72
    ) -> Match? {
        let queryTerms = terms(from: instruction)
        guard queryTerms.count >= 2 else {
            localMisses += 1
            return nil
        }

        let candidates = VerifiedLearningStore.shared.recentExamples(
            capabilityId: capabilityId,
            projectId: projectId,
            limit: 250
        )

        var best: Match?
        for example in candidates {
            let candidateTerms = terms(from: example.title + " " + example.instruction)
            guard !candidateTerms.isEmpty else { continue }

            let overlap = queryTerms.intersection(candidateTerms)
            guard !overlap.isEmpty else { continue }

            let queryCoverage = Double(overlap.count) / Double(queryTerms.count)
            let candidateCoverage = Double(overlap.count) / Double(candidateTerms.count)
            let capabilityBoost = capabilityId == nil || example.capabilityId == capabilityId ? 0.10 : 0
            let projectBoost = projectId != nil && example.projectId == projectId ? 0.08 : 0
            let score = min(1, queryCoverage * 0.68 + candidateCoverage * 0.14 + capabilityBoost + projectBoost)

            let match = Match(
                example: example,
                confidence: score,
                matchedTerms: overlap.sorted()
            )
            if best == nil || match.confidence > best!.confidence { best = match }
        }

        guard let best, best.confidence >= minimumConfidence else {
            localMisses += 1
            return nil
        }
        localHits += 1
        return best
    }

    /// A compact, provenance-backed local answer. The caller decides whether
    /// it can safely reuse the prior result or should still execute/verify it.
    func reusableKnowledge(
        instruction: String,
        capabilityId: String? = nil,
        projectId: UUID? = nil,
        minimumConfidence: Double = 0.72
    ) -> String? {
        guard let match = bestMatch(
            instruction: instruction,
            capabilityId: capabilityId,
            projectId: projectId,
            minimumConfidence: minimumConfidence
        ) else { return nil }

        return """
        LOCAL VERIFIED SKILL
        confidence: \(Int(match.confidence * 100))%
        capability: \(match.example.capabilityId)
        prior instruction: \(match.example.instruction)
        verified result: \(match.example.verifiedResult)
        matched terms: \(match.matchedTerms.joined(separator: ", "))
        """
    }

    var localReuseRate: Double {
        let total = localHits + localMisses
        guard total > 0 else { return 0 }
        return Double(localHits) / Double(total)
    }

    private func terms(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "this", "that", "with", "from", "into", "then", "than", "when", "where", "what", "have", "will", "should", "could", "would", "your", "their", "there", "about", "after", "before", "using", "make", "create", "check", "please",
            "και", "που", "την", "τον", "των", "στο", "στη", "στην", "απο", "για", "με", "να", "το", "τα", "της", "του", "ενα", "μια", "πως", "οταν"
        ]
        return Set(
            text.lowercased()
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }
}
