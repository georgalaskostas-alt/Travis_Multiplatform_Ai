import Foundation
import Observation

/// Builds a durable, privacy-minimized training corpus exclusively from
/// completed runtime tasks. It is NOT a trainer: it prepares auditable examples
/// that a future local-model trainer may consume after explicit promotion rules.
@MainActor
@Observable
final class TrainingDatasetPipeline {
    static let shared = TrainingDatasetPipeline()

    enum DatasetKind: String, Codable, Hashable, CaseIterable {
        case routing
        case instructionFollowing
        case verification
        case workflow
    }

    struct TrainingExample: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var sourceTaskId: UUID
        var sourceStepId: UUID?
        var sourcePlanVersion: Int
        var capabilityId: String?
        var kind: DatasetKind
        var input: String
        var target: String
        var qualityScore: Double
        var provenance: String
        var redactionsApplied: Int

        init(
            id: UUID = UUID(),
            createdAt: Date = Date(),
            sourceTaskId: UUID,
            sourceStepId: UUID?,
            sourcePlanVersion: Int,
            capabilityId: String?,
            kind: DatasetKind,
            input: String,
            target: String,
            qualityScore: Double,
            provenance: String,
            redactionsApplied: Int
        ) {
            self.id = id
            self.createdAt = createdAt
            self.sourceTaskId = sourceTaskId
            self.sourceStepId = sourceStepId
            self.sourcePlanVersion = sourcePlanVersion
            self.capabilityId = capabilityId
            self.kind = kind
            self.input = input
            self.target = target
            self.qualityScore = min(max(qualityScore, 0), 1)
            self.provenance = provenance
            self.redactionsApplied = max(0, redactionsApplied)
        }
    }

    private struct Snapshot: Codable {
        var version: Int
        var examples: [TrainingExample]
    }

    private(set) var examples: [TrainingExample] = []
    private(set) var persistenceError: String?

    private let maxExamples = 30_000
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("training-dataset-v1.json")
        reload()
    }

    func ingestCompletedTask(_ task: AgentTask) {
        guard task.status == .completed else { return }

        var pending: [TrainingExample] = []
        for step in task.plan.steps.sorted(by: { $0.order < $1.order }) where step.status == .completed {
            guard let capabilityId = step.capabilityId,
                  let result = step.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty else { continue }

            guard !examples.contains(where: {
                $0.sourceTaskId == task.id &&
                $0.sourceStepId == step.id &&
                $0.sourcePlanVersion == task.plan.version &&
                $0.kind == .instructionFollowing
            }) else { continue }

            let inputRaw = """
            capability: \(capabilityId)
            title: \(step.title)
            instruction: \(step.instructions)
            successCriteria: \(step.successCriteria.joined(separator: " | "))
            """
            let inputSanitized = sanitize(String(inputRaw.prefix(12_000)))
            let targetSanitized = sanitize(String(result.prefix(16_000)))

            guard passesQualityGate(input: inputSanitized.text, target: targetSanitized.text) else { continue }

            let score = qualityScore(step: step, input: inputSanitized.text, target: targetSanitized.text)
            guard score >= 0.72 else { continue }

            pending.append(TrainingExample(
                sourceTaskId: task.id,
                sourceStepId: step.id,
                sourcePlanVersion: task.plan.version,
                capabilityId: capabilityId,
                kind: .instructionFollowing,
                input: inputSanitized.text,
                target: targetSanitized.text,
                qualityScore: score,
                provenance: "completed runtime task; step status=completed; resultSummary persisted after verifier pass/runtime completion",
                redactionsApplied: inputSanitized.redactions + targetSanitized.redactions
            ))

            let routingInput = sanitize(String(task.goal.prefix(6_000)))
            if !routingInput.text.isEmpty {
                pending.append(TrainingExample(
                    sourceTaskId: task.id,
                    sourceStepId: step.id,
                    sourcePlanVersion: task.plan.version,
                    capabilityId: capabilityId,
                    kind: .routing,
                    input: routingInput.text,
                    target: capabilityId,
                    qualityScore: min(0.98, score + 0.04),
                    provenance: "verified completed step capability assignment",
                    redactionsApplied: routingInput.redactions
                ))
            }
        }

        if task.plan.steps.count >= 2,
           task.plan.steps.allSatisfy({ $0.status == .completed }) {
            let workflowInput = sanitize(String(task.goal.prefix(6_000)))
            let workflowTargetRaw = task.plan.steps.sorted(by: { $0.order < $1.order }).map { step in
                "\(step.order)|\(step.capabilityId ?? "unassigned")|\(step.title)|\(step.instructions)"
            }.joined(separator: "\n")
            let workflowTarget = sanitize(String(workflowTargetRaw.prefix(20_000)))

            if passesQualityGate(input: workflowInput.text, target: workflowTarget.text) {
                pending.append(TrainingExample(
                    sourceTaskId: task.id,
                    sourceStepId: nil,
                    sourcePlanVersion: task.plan.version,
                    capabilityId: nil,
                    kind: .workflow,
                    input: workflowInput.text,
                    target: workflowTarget.text,
                    qualityScore: 0.88,
                    provenance: "fully completed verified task plan",
                    redactionsApplied: workflowInput.redactions + workflowTarget.redactions
                ))
            }
        }

        guard !pending.isEmpty else { return }
        examples.append(contentsOf: pending)
        deduplicateAndBound()
        persist()
    }

    func exportableExamples(kind: DatasetKind? = nil, minimumQuality: Double = 0.85, limit: Int = 10_000) -> [TrainingExample] {
        examples
            .filter { (kind == nil || $0.kind == kind) && $0.qualityScore >= minimumQuality }
            .suffix(max(1, min(limit, 10_000)))
            .map { $0 }
    }

    func diagnosticReport() -> String {
        let grouped = Dictionary(grouping: examples, by: \.kind)
        let rows = DatasetKind.allCases.map { kind in
            let values = grouped[kind] ?? []
            let mature = values.filter { $0.qualityScore >= 0.85 }.count
            return "\(kind.rawValue): \(values.count) total / \(mature) promotion-ready"
        }.joined(separator: "\n")
        let redactions = examples.reduce(0) { $0 + $1.redactionsApplied }

        return """
        TRAVIS TRAINING DATASET

        TOTAL
        \(examples.count)

        BY KIND
        \(rows)

        REDACTIONS APPLIED
        \(redactions)

        Dataset preparation only. No model is trained or promoted automatically from these examples.
        """
    }

    private func qualityScore(step: PlanStep, input: String, target: String) -> Double {
        var score = 0.72
        if !step.successCriteria.isEmpty { score += 0.08 }
        if target.count >= 80 { score += 0.06 }
        if input.count >= 40 { score += 0.04 }
        if step.attemptCount <= 1 { score += 0.04 }
        if step.lastError == nil { score += 0.04 }
        return min(score, 0.98)
    }

    private func passesQualityGate(input: String, target: String) -> Bool {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanInput.count >= 12, cleanTarget.count >= 12 else { return false }
        guard !cleanTarget.localizedCaseInsensitiveContains("runtime execution error") else { return false }
        guard !cleanTarget.localizedCaseInsensitiveContains("verification failed") else { return false }
        return true
    }

    private func sanitize(_ value: String) -> (text: String, redactions: Int) {
        var text = value
        var count = 0

        let patterns: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{12,}"#, "[REDACTED_API_KEY]"),
            (#"(?i)(api[_ -]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"/Users/[^/\s]+"#, "/Users/[USER]"),
            (#"(?i)bearer\s+[A-Za-z0-9._\-]{12,}"#, "Bearer [REDACTED]"),
            (#"[A-Fa-f0-9]{32,}"#, "[REDACTED_LONG_HEX]" )
        ]

        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.numberOfMatches(in: text, range: range)
            if matches > 0 {
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
                count += matches
            }
        }

        return (text, count)
    }

    private func deduplicateAndBound() {
        var seen = Set<String>()
        examples = examples.reversed().filter { example in
            let fingerprint = "\(example.kind.rawValue)|\(example.capabilityId ?? "-")|\(example.input)|\(example.target)"
            return seen.insert(fingerprint).inserted
        }.reversed()

        if examples.count > maxExamples {
            examples.removeFirst(examples.count - maxExamples)
        }
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { return }
            examples = snapshot.examples
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, examples: examples)
            let data = try JSONEncoder().encode(snapshot)
            let temporaryURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
