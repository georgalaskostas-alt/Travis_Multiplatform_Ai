import Foundation
import Observation

/// Durable seed dataset for TRAVIS local learning.
/// Only verified runtime outcomes may enter this store. It is intentionally
/// separate from chat memory so unverified model prose can never become
/// training truth by accident.
@MainActor
@Observable
final class VerifiedLearningStore {
    static let shared = VerifiedLearningStore()

    struct Example: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var taskId: UUID
        var stepId: UUID
        var projectId: UUID?
        var capabilityId: String
        var title: String
        var instruction: String
        var successCriteria: [String]
        var verifiedResult: String
        var sourcePlanVersion: Int

        init(id: UUID = UUID(), createdAt: Date = Date(), taskId: UUID, stepId: UUID, projectId: UUID?, capabilityId: String, title: String, instruction: String, successCriteria: [String], verifiedResult: String, sourcePlanVersion: Int) {
            self.id = id; self.createdAt = createdAt; self.taskId = taskId; self.stepId = stepId; self.projectId = projectId; self.capabilityId = capabilityId; self.title = title; self.instruction = instruction; self.successCriteria = successCriteria; self.verifiedResult = verifiedResult; self.sourcePlanVersion = sourcePlanVersion
        }
    }

    private struct Snapshot: Codable { var version: Int; var examples: [Example] }
    private(set) var examples: [Example] = []
    private(set) var persistenceError: String?
    private let maxExamples = 20_000
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("verified-learning-v1.json")
        reload()
        rebuildLocalProjections()
    }

    func ingestCompletedTask(_ task: AgentTask, projectId: UUID?) {
        guard task.status == .completed else { return }
        var changed = false
        for step in task.plan.steps where step.status == .completed {
            guard let capabilityId = step.capabilityId?.trimmingCharacters(in: .whitespacesAndNewlines), !capabilityId.isEmpty,
                  let result = step.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { continue }
            guard !examples.contains(where: { $0.taskId == task.id && $0.stepId == step.id && $0.sourcePlanVersion == task.plan.version }) else { continue }
            examples.append(Example(taskId: task.id, stepId: step.id, projectId: projectId, capabilityId: capabilityId, title: step.title, instruction: String(step.instructions.prefix(12_000)), successCriteria: step.successCriteria, verifiedResult: String(result.prefix(16_000)), sourcePlanVersion: task.plan.version))
            changed = true
        }
        if examples.count > maxExamples { examples.removeFirst(examples.count - maxExamples); changed = true }
        if changed { rebuildLocalProjections(); persist() }
    }

    func recentExamples(capabilityId: String? = nil, projectId: UUID? = nil, limit: Int = 50) -> [Example] {
        let bounded = max(1, min(limit, 500))
        return examples.reversed().filter { example in
            (capabilityId == nil || example.capabilityId == capabilityId) && (projectId == nil || example.projectId == projectId)
        }.prefix(bounded).map { $0 }
    }

    func contextBlock(capabilityId: String, projectId: UUID? = nil, limit: Int = 5) -> String {
        let selected = recentExamples(capabilityId: capabilityId, projectId: projectId, limit: limit)
        guard !selected.isEmpty else { return "" }
        return selected.map { example in
            """
            VERIFIED EXAMPLE
            title: \(example.title)
            instruction: \(example.instruction)
            success criteria: \(example.successCriteria.joined(separator: " | "))
            verified result: \(example.verifiedResult)
            """
        }.joined(separator: "\n\n")
    }

    func diagnosticReport() -> String {
        let grouped = Dictionary(grouping: examples, by: \.capabilityId)
        let rows = grouped.map { key, values in "\(key): \(values.count) verified examples" }.sorted().joined(separator: "\n")
        return """
        TRAVIS VERIFIED LEARNING

        TOTAL VERIFIED EXAMPLES
        \(examples.count)

        BY CAPABILITY
        \(rows.isEmpty ? "κανένα" : rows)

        LOCAL VERIFICATION SAVES
        \(LearnedVerificationRegistry.shared.localVerificationHits)

        LEARNED EXECUTION GUIDANCE HITS
        \(LearnedExecutionRegistry.shared.hits)

        Only completed, verified runtime step outputs are eligible.
        """
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { rebuildLocalProjections(); return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { return }
            examples = snapshot.examples
            rebuildLocalProjections()
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    private func rebuildLocalProjections() {
        LearnedVerificationRegistry.shared.rebuild(from: examples)
        LearnedExecutionRegistry.shared.rebuild(from: examples)
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, examples: examples)
            let data = try JSONEncoder().encode(snapshot)
            let temporaryURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) { _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL) }
            else { try FileManager.default.moveItem(at: temporaryURL, to: fileURL) }
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
}
