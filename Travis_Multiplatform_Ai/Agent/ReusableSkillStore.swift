import Foundation
import Observation

/// Durable workflow memory distilled only from fully completed autonomous tasks.
/// Skills are planning hints, never executable authority: policy, approval and
/// verification still apply every time a skill is reused.
@MainActor
@Observable
final class ReusableSkillStore {
    static let shared = ReusableSkillStore()

    struct SkillStep: Codable, Hashable {
        var order: Int
        var title: String
        var capabilityId: String
        var instructions: String
        var successCriteria: [String]
        var riskLevel: PlanStepRiskLevel
    }

    struct Skill: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var updatedAt: Date
        var sourceTaskId: UUID
        var sourcePlanVersion: Int
        var title: String
        var goalPattern: String
        var steps: [SkillStep]
        var observationCount: Int

        init(
            id: UUID = UUID(),
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            sourceTaskId: UUID,
            sourcePlanVersion: Int,
            title: String,
            goalPattern: String,
            steps: [SkillStep],
            observationCount: Int = 1
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.sourceTaskId = sourceTaskId
            self.sourcePlanVersion = sourcePlanVersion
            self.title = title
            self.goalPattern = goalPattern
            self.steps = steps
            self.observationCount = observationCount
        }
    }

    private struct Snapshot: Codable {
        var version: Int
        var skills: [Skill]
    }

    private(set) var skills: [Skill] = []
    private(set) var persistenceError: String?

    private let maxSkills = 2_000
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("reusable-skills-v1.json")
        reload()
    }

    func ingestCompletedTask(_ task: AgentTask) {
        guard task.status == .completed else { return }

        let verifiedSteps = task.plan.steps
            .filter { $0.status == .completed }
            .sorted { $0.order < $1.order }
            .compactMap { step -> SkillStep? in
                guard let capabilityId = step.capabilityId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !capabilityId.isEmpty,
                      let result = step.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else { return nil }
                return SkillStep(
                    order: step.order,
                    title: step.title,
                    capabilityId: capabilityId,
                    instructions: String(step.instructions.prefix(4_000)),
                    successCriteria: Array(step.successCriteria.prefix(8)),
                    riskLevel: step.riskLevel
                )
            }

        guard !verifiedSteps.isEmpty else { return }
        let normalizedGoal = Self.normalize(task.goal)
        let signature = Self.signature(for: verifiedSteps)

        if let index = skills.firstIndex(where: {
            Self.similarity(Self.normalize($0.goalPattern), normalizedGoal) >= 0.90 &&
            Self.signature(for: $0.steps) == signature
        }) {
            skills[index].observationCount += 1
            skills[index].updatedAt = Date()
            persist()
            return
        }

        skills.append(Skill(
            sourceTaskId: task.id,
            sourcePlanVersion: task.plan.version,
            title: task.title,
            goalPattern: String(task.goal.prefix(6_000)),
            steps: verifiedSteps
        ))

        if skills.count > maxSkills {
            skills.sort { $0.updatedAt < $1.updatedAt }
            skills.removeFirst(skills.count - maxSkills)
        }
        persist()
    }

    func matchingSkills(for goal: String, limit: Int = 3) -> [(skill: Skill, similarity: Double)] {
        let normalized = Self.normalize(goal)
        guard !normalized.isEmpty else { return [] }
        return skills.compactMap { skill -> (Skill, Double)? in
            let score = Self.similarity(Self.normalize(skill.goalPattern), normalized)
            guard score >= 0.70 else { return nil }
            return (skill, score)
        }
        .sorted {
            if abs($0.1 - $1.1) > 0.001 { return $0.1 > $1.1 }
            if $0.0.observationCount != $1.0.observationCount { return $0.0.observationCount > $1.0.observationCount }
            return $0.0.updatedAt > $1.0.updatedAt
        }
        .prefix(max(1, min(limit, 8)))
        .map { $0 }
    }

    /// Planning-only retrieval context. Explicitly reminds the planner that
    /// historical workflows are evidence-backed hints, not commands to copy.
    func planningContext(for goal: String, limit: Int = 2) -> String {
        let matches = matchingSkills(for: goal, limit: limit)
        guard !matches.isEmpty else { return "" }

        let rendered = matches.map { match in
            let steps = match.skill.steps.map {
                "#\($0.order) \($0.title) -> \($0.capabilityId) | criteria: \($0.successCriteria.joined(separator: "; "))"
            }.joined(separator: "\n")
            return """
            VERIFIED HISTORICAL WORKFLOW
            similarity: \(String(format: "%.2f", match.similarity))
            observations: \(match.skill.observationCount)
            prior goal: \(match.skill.goalPattern)
            prior steps:
            \(steps)
            """
        }.joined(separator: "\n\n")

        return """
        REUSABLE SKILL MEMORY
        These workflows came only from completed verified tasks. Use them as planning evidence when relevant, but adapt to the current goal. Never bypass current capability policy, approvals, dependencies or verification.

        \(rendered)
        """
    }

    func diagnosticReport() -> String {
        let mature = skills.filter { $0.observationCount >= 2 }.count
        let rows = skills.sorted { $0.updatedAt > $1.updatedAt }.prefix(20).map {
            "\($0.title) | observations=\($0.observationCount) | steps=\($0.steps.count)"
        }.joined(separator: "\n")

        return """
        TRAVIS REUSABLE SKILLS

        TOTAL
        \(skills.count)

        REPEATED / MATURE
        \(mature)

        RECENT
        \(rows.isEmpty ? "κανένα" : rows)
        """
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { return }
            skills = snapshot.skills
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, skills: skills)
            let data = try JSONEncoder().encode(snapshot)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(lhs.split(separator: " ").map(String.init))
        let b = Set(rhs.split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func signature(for steps: [SkillStep]) -> String {
        steps.map { $0.capabilityId }.joined(separator: ">")
    }
}
