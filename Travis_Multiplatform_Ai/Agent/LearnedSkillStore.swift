import Foundation
import Observation

/// Builds reusable local skills only from repeated VERIFIED runtime examples.
/// No external model is required to create or match these skills.
@MainActor
@Observable
final class LearnedSkillStore {
    static let shared = LearnedSkillStore()

    struct Skill: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var updatedAt: Date
        var capabilityId: String
        var projectId: UUID?
        var signatureTerms: [String]
        var provenExamples: Int
        var confidence: Double
        var representativeInstruction: String
        var representativeResult: String
        var successCriteria: [String]
        var useCount: Int
        var lastUsedAt: Date?
    }

    struct Match: Hashable {
        let skill: Skill
        let confidence: Double
    }

    private struct Snapshot: Codable { var version: Int; var skills: [Skill] }
    private(set) var skills: [Skill] = []
    private let fileURL: URL
    private let minimumExamples = 2

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("learned-skills-v1.json")
        reload()
    }

    func rebuild(from examples: [VerifiedLearningStore.Example]) {
        var built: [Skill] = []
        let grouped = Dictionary(grouping: examples, by: { $0.capabilityId })

        for (capabilityId, capabilityExamples) in grouped {
            var consumed = Set<UUID>()
            for seed in capabilityExamples.reversed() where !consumed.contains(seed.id) {
                let seedTerms = Self.terms(seed.title + " " + seed.instruction)
                guard seedTerms.count >= 3 else { continue }
                let cluster = capabilityExamples.filter { candidate in
                    guard !consumed.contains(candidate.id) else { return false }
                    let candidateTerms = Self.terms(candidate.title + " " + candidate.instruction)
                    return Self.similarity(seedTerms, candidateTerms) >= 0.68
                }
                guard cluster.count >= minimumExamples else { continue }
                cluster.forEach { consumed.insert($0.id) }
                let common = cluster.dropFirst().reduce(seedTerms) { partial, example in
                    partial.intersection(Self.terms(example.title + " " + example.instruction))
                }
                guard common.count >= 2 else { continue }
                let projectIds = Set(cluster.compactMap(\.projectId))
                let confidence = min(0.98, 0.72 + Double(cluster.count - minimumExamples) * 0.04 + (projectIds.count == 1 && !projectIds.isEmpty ? 0.06 : 0))
                let latest = cluster.max(by: { $0.createdAt < $1.createdAt }) ?? seed
                built.append(Skill(
                    id: UUID(), createdAt: Date(), updatedAt: Date(), capabilityId: capabilityId,
                    projectId: projectIds.count == 1 ? projectIds.first : nil,
                    signatureTerms: common.sorted(), provenExamples: cluster.count, confidence: confidence,
                    representativeInstruction: latest.instruction,
                    representativeResult: latest.verifiedResult,
                    successCriteria: latest.successCriteria, useCount: 0, lastUsedAt: nil
                ))
            }
        }

        // Preserve usage history when a rebuilt skill strongly resembles an old one.
        for index in built.indices {
            let newTerms = Set(built[index].signatureTerms)
            if let old = skills.max(by: { Self.similarity(newTerms, Set($0.signatureTerms)) < Self.similarity(newTerms, Set($1.signatureTerms)) }),
               old.capabilityId == built[index].capabilityId,
               Self.similarity(newTerms, Set(old.signatureTerms)) >= 0.75 {
                built[index].useCount = old.useCount
                built[index].lastUsedAt = old.lastUsedAt
                built[index].createdAt = old.createdAt
            }
        }
        skills = built
        persist()
    }

    func bestMatch(instruction: String, capabilityId: String, projectId: UUID?, minimumConfidence: Double = 0.80) -> Match? {
        let query = Self.terms(instruction)
        guard query.count >= 3 else { return nil }
        var best: Match?
        for skill in skills where skill.capabilityId == capabilityId {
            let overlap = Self.similarity(query, Set(skill.signatureTerms))
            let projectBoost = projectId != nil && skill.projectId == projectId ? 0.08 : 0
            let score = min(1, overlap * 0.72 + skill.confidence * 0.20 + projectBoost)
            if score >= minimumConfidence && (best == nil || score > best!.confidence) { best = Match(skill: skill, confidence: score) }
        }
        return best
    }

    func markUsed(_ id: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].useCount += 1
        skills[index].lastUsedAt = Date()
        persist()
    }

    func guidance(_ match: Match) -> String {
        """
        LEARNED LOCAL SKILL
        confidence: \(Int(match.confidence * 100))%
        proven verified examples: \(match.skill.provenExamples)
        reusable pattern: \(match.skill.signatureTerms.joined(separator: ", "))
        representative proven instruction: \(match.skill.representativeInstruction)
        representative verified result: \(match.skill.representativeResult)
        Treat this as learned procedure evidence, not as current-state evidence. Re-check current inputs before acting.
        """
    }

    var report: String {
        let uses = skills.reduce(0) { $0 + $1.useCount }
        return "TRAVIS LEARNED SKILLS\nskills: \(skills.count)\nuses: \(uses)\nverified examples required per skill: \(minimumExamples)"
    }

    private func reload() {
        guard let data = try? Data(contentsOf: fileURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return }
        skills = snapshot.skills
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(version: 1, skills: skills)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
    private static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["this","that","with","from","into","then","when","where","what","have","will","should","using","make","create","check","please","και","που","την","τον","των","στο","στη","στην","απο","για","με","να","το","τα","της","του","ενα","μια","πως","οταν"]
        return Set(text.lowercased().folding(options: [.diacriticInsensitive,.caseInsensitive], locale: .current).split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
    }
}
