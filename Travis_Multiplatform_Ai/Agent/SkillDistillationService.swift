import Foundation

@MainActor
final class SkillDistillationService {
    enum ExecutionClass: String, Codable, Hashable {
        case deterministicCandidate
        case localAICandidate
        case cloudReasoningRequired
    }

    struct DistilledSkill: Identifiable, Codable, Hashable {
        let id: UUID
        var sourceSkillId: UUID
        var updatedAt: Date
        var executionClass: ExecutionClass
        var confidence: Double
        var rationale: String
        var capabilityIds: [String]
        var observationCount: Int
    }

    private struct Snapshot: Codable {
        var version: Int
        var items: [DistilledSkill]
    }

    static let shared = SkillDistillationService()

    private(set) var items: [DistilledSkill] = []
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("distilled-skills-v1.json")
        reload()
    }

    func refresh(skills: [ReusableSkillStore.Skill], capabilities: [AgentCapability]) {
        let descriptors = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0.descriptor) })
        var rebuilt: [DistilledSkill] = []
        rebuilt.reserveCapacity(skills.count)

        for skill in skills {
            let result = classify(skill, descriptors: descriptors)
            rebuilt.append(DistilledSkill(
                id: existingId(for: skill.id) ?? UUID(),
                sourceSkillId: skill.id,
                updatedAt: Date(),
                executionClass: result.classification,
                confidence: result.confidence,
                rationale: result.rationale,
                capabilityIds: Array(Set(skill.steps.map(\.capabilityId))).sorted(),
                observationCount: skill.observationCount
            ))
        }

        items = rebuilt
        persist()
    }

    func diagnosticReport() -> String {
        let grouped = Dictionary(grouping: items, by: \.executionClass)
        let rows = ExecutionClass.allCasesForDiagnostics.map { kind in
            "\(kind.rawValue): \(grouped[kind]?.count ?? 0)"
        }.joined(separator: "\n")
        return """
        TRAVIS SKILL DISTILLATION

        TOTAL
        \(items.count)

        BY EXECUTION CLASS
        \(rows)

        Deterministic/local candidates are classifications only. They do not bypass policy, approvals or verification.
        """
    }

    private func classify(
        _ skill: ReusableSkillStore.Skill,
        descriptors: [String: CapabilityDescriptor]
    ) -> (classification: ExecutionClass, confidence: Double, rationale: String) {
        guard skill.observationCount >= 2 else {
            return (.cloudReasoningRequired, 0.55, "Skill is not mature enough for local distillation.")
        }

        let skillDescriptors = skill.steps.compactMap { descriptors[$0.capabilityId] }
        guard skillDescriptors.count == skill.steps.count else {
            return (.cloudReasoningRequired, 0.60, "One or more capabilities lack a registered descriptor.")
        }

        let effects = Set(skillDescriptors.flatMap { $0.policy.declaredEffects })
        if !effects.isDisjoint(with: [.financial, .externalMutation, .codeMutation]) {
            return (.cloudReasoningRequired, 0.99, "Workflow contains consequential external, financial or source-code mutation effects.")
        }

        let domains = Set(skillDescriptors.map(\.domain))
        let deterministicDomains: Set<CapabilityDomain> = [.files, .system, .automation, .productivity]
        if effects.isSubset(of: [.readOnly, .localMutation]),
           domains.isSubset(of: deterministicDomains) {
            return (.deterministicCandidate, 0.90, "Repeated workflow is bounded to local/read-only deterministic-capable domains.")
        }

        if effects.isSubset(of: [.readOnly, .localMutation]) {
            return (.localAICandidate, 0.82, "Repeated workflow is non-consequential but still requires semantic/reasoning capability.")
        }

        return (.cloudReasoningRequired, 0.80, "Workflow still requires cloud-grade reasoning or unsupported execution semantics.")
    }

    private func existingId(for sourceSkillId: UUID) -> UUID? {
        items.first(where: { $0.sourceSkillId == sourceSkillId })?.id
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return }
        items = snapshot.items
    }

    private func persist() {
        let snapshot = Snapshot(version: 1, items: items)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

private extension SkillDistillationService.ExecutionClass {
    static var allCasesForDiagnostics: [SkillDistillationService.ExecutionClass] {
        [.deterministicCandidate, .localAICandidate, .cloudReasoningRequired]
    }
}
