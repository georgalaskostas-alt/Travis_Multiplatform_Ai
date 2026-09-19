import Foundation
import Observation

/// Keeps runtime feedback for reusable skills separate from the verified skill
/// definitions. Successful reuse raises trust slowly; failed reuse lowers it
/// quickly and can temporarily disable local reuse.
@MainActor
@Observable
final class SkillConfidenceStore {
    static let shared = SkillConfidenceStore()

    struct Feedback: Codable, Hashable {
        var successes: Int = 0
        var failures: Int = 0
        var consecutiveFailures: Int = 0
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var disabledUntil: Date?
    }

    private struct Snapshot: Codable {
        var version: Int
        var values: [String: Feedback]
    }

    private(set) var values: [String: Feedback] = [:]
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("skill-confidence-v1.json")
        reload()
    }

    func key(for skill: ReusableSkillStore.Skill) -> String {
        let capabilities = skill.steps.sorted(by: { $0.order < $1.order }).map(\.capabilityId).joined(separator: ">")
        return skill.goalPattern.lowercased().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) + "|" + capabilities
    }

    func effectiveConfidence(base: Double, skill: ReusableSkillStore.Skill) -> Double {
        let feedback = values[key(for: skill)] ?? Feedback()
        if let until = feedback.disabledUntil, until > Date() { return 0 }
        let successBoost = min(0.10, Double(feedback.successes) * 0.015)
        let failurePenalty = min(0.55, Double(feedback.failures) * 0.08 + Double(feedback.consecutiveFailures) * 0.12)
        return min(0.99, max(0, base + successBoost - failurePenalty))
    }

    func recordSuccess(skill: ReusableSkillStore.Skill) {
        let key = key(for: skill)
        var feedback = values[key] ?? Feedback()
        feedback.successes += 1
        feedback.consecutiveFailures = 0
        feedback.lastSuccessAt = Date()
        feedback.disabledUntil = nil
        values[key] = feedback
        persist()
    }

    func recordFailure(skill: ReusableSkillStore.Skill) {
        let key = key(for: skill)
        var feedback = values[key] ?? Feedback()
        feedback.failures += 1
        feedback.consecutiveFailures += 1
        feedback.lastFailureAt = Date()
        if feedback.consecutiveFailures >= 2 {
            feedback.disabledUntil = Calendar.current.date(byAdding: .hour, value: 24, to: Date())
        }
        values[key] = feedback
        persist()
    }

    func diagnosticReport() -> String {
        let disabled = values.values.filter { ($0.disabledUntil ?? .distantPast) > Date() }.count
        let successes = values.values.reduce(0) { $0 + $1.successes }
        let failures = values.values.reduce(0) { $0 + $1.failures }
        return "TRAVIS SKILL CONFIDENCE\ntracked: \(values.count)\nsuccessful reuses: \(successes)\nfailed reuses: \(failures)\ntemporarily disabled: \(disabled)"
    }

    private func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return }
        values = snapshot.values
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(version: 1, values: values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
