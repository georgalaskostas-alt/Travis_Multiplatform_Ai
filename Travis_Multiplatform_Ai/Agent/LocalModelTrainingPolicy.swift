import Foundation
import Observation

/// Governance layer for future local-model training. This service does not
/// launch a trainer process by itself. It defines when a dataset/model is
/// eligible for training, evaluation and routing promotion.
@MainActor
@Observable
final class LocalModelTrainingPolicy {
    static let shared = LocalModelTrainingPolicy()

    enum Stage: String, Codable, Hashable, CaseIterable {
        case collecting
        case trainingEligible
        case evaluating
        case candidate
        case promoted
        case rejected
        case rolledBack
    }

    struct ModelCandidate: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var datasetKind: TrainingDatasetPipeline.DatasetKind
        var stage: Stage
        var datasetExampleCount: Int
        var minimumQuality: Double
        var holdoutAccuracy: Double?
        var baselineAccuracy: Double?
        var meanLatencyMs: Double?
        var estimatedCostPer1KRequestsUSD: Double?
        var trainingArtifactLocation: String?
        var rejectionReason: String?

        init(
            id: UUID = UUID(),
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            name: String,
            datasetKind: TrainingDatasetPipeline.DatasetKind,
            stage: Stage,
            datasetExampleCount: Int,
            minimumQuality: Double
        ) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.name = name
            self.datasetKind = datasetKind
            self.stage = stage
            self.datasetExampleCount = datasetExampleCount
            self.minimumQuality = minimumQuality
        }
    }

    struct Eligibility: Hashable {
        var eligible: Bool
        var exampleCount: Int
        var requiredCount: Int
        var minimumQuality: Double
        var reason: String
    }

    private struct Snapshot: Codable {
        var version: Int
        var candidates: [ModelCandidate]
    }

    private(set) var candidates: [ModelCandidate] = []
    private(set) var persistenceError: String?
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("local-model-candidates-v1.json")
        reload()
    }

    func eligibility(for kind: TrainingDatasetPipeline.DatasetKind) -> Eligibility {
        let minimumQuality = minimumQualityForTraining(kind)
        let required = minimumExamples(kind)
        let count = TrainingDatasetPipeline.shared.exportableExamples(
            kind: kind,
            minimumQuality: minimumQuality,
            limit: 10_000
        ).count

        return Eligibility(
            eligible: count >= required,
            exampleCount: count,
            requiredCount: required,
            minimumQuality: minimumQuality,
            reason: count >= required
                ? "Dataset meets the minimum verified sample and quality gate."
                : "Need \(required - count) more verified examples at quality >= \(String(format: "%.2f", minimumQuality))."
        )
    }

    @discardableResult
    func registerTrainingCandidate(name: String, kind: TrainingDatasetPipeline.DatasetKind) -> ModelCandidate? {
        let status = eligibility(for: kind)
        guard status.eligible else { return nil }

        let candidate = ModelCandidate(
            name: name,
            datasetKind: kind,
            stage: .trainingEligible,
            datasetExampleCount: status.exampleCount,
            minimumQuality: status.minimumQuality
        )
        candidates.append(candidate)
        persist()
        return candidate
    }

    /// Records evaluation only. Promotion is allowed when the candidate beats
    /// or matches the baseline with minimum absolute quality and acceptable
    /// latency. This prevents automatic promotion merely because training ran.
    func recordEvaluation(
        candidateId: UUID,
        holdoutAccuracy: Double,
        baselineAccuracy: Double,
        meanLatencyMs: Double,
        artifactLocation: String?
    ) {
        guard let index = candidates.firstIndex(where: { $0.id == candidateId }) else { return }
        let accuracy = min(max(holdoutAccuracy, 0), 1)
        let baseline = min(max(baselineAccuracy, 0), 1)
        let latency = max(0, meanLatencyMs)

        candidates[index].holdoutAccuracy = accuracy
        candidates[index].baselineAccuracy = baseline
        candidates[index].meanLatencyMs = latency
        candidates[index].trainingArtifactLocation = artifactLocation
        candidates[index].updatedAt = Date()

        let minimumAccuracy = minimumHoldoutAccuracy(candidates[index].datasetKind)
        let acceptableRegression = 0.01
        if accuracy >= minimumAccuracy,
           accuracy + acceptableRegression >= baseline,
           latency <= 1_500 {
            candidates[index].stage = .candidate
            candidates[index].rejectionReason = nil
        } else {
            candidates[index].stage = .rejected
            candidates[index].rejectionReason = "Evaluation gate failed: accuracy=\(String(format: "%.3f", accuracy)), baseline=\(String(format: "%.3f", baseline)), latency=\(Int(latency))ms."
        }
        persist()
    }

    /// Promotion is deliberately explicit. Nothing in dataset ingestion or
    /// evaluation silently changes the production routing configuration.
    func promote(candidateId: UUID) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == candidateId }),
              candidates[index].stage == .candidate,
              candidates[index].trainingArtifactLocation != nil else { return false }
        candidates[index].stage = .promoted
        candidates[index].updatedAt = Date()
        persist()
        return true
    }

    func rollback(candidateId: UUID, reason: String) {
        guard let index = candidates.firstIndex(where: { $0.id == candidateId }) else { return }
        candidates[index].stage = .rolledBack
        candidates[index].rejectionReason = reason
        candidates[index].updatedAt = Date()
        persist()
    }

    func diagnosticReport() -> String {
        let eligibilityRows = TrainingDatasetPipeline.DatasetKind.allCases.map { kind in
            let value = eligibility(for: kind)
            return "\(kind.rawValue): \(value.exampleCount)/\(value.requiredCount) @ quality >= \(String(format: "%.2f", value.minimumQuality)) — \(value.eligible ? "eligible" : "collecting")"
        }.joined(separator: "\n")

        let candidateRows = candidates.suffix(12).map { candidate in
            "\(candidate.name) [\(candidate.stage.rawValue)] kind=\(candidate.datasetKind.rawValue) n=\(candidate.datasetExampleCount)"
        }.joined(separator: "\n")

        return """
        TRAVIS LOCAL MODEL TRAINING POLICY

        DATASET ELIGIBILITY
        \(eligibilityRows)

        RECENT MODEL CANDIDATES
        \(candidateRows.isEmpty ? "κανένα" : candidateRows)

        Training/promotion is gated. No model becomes active merely because examples were collected.
        """
    }

    private func minimumExamples(_ kind: TrainingDatasetPipeline.DatasetKind) -> Int {
        switch kind {
        case .routing: return 250
        case .verification: return 500
        case .instructionFollowing: return 1_000
        case .workflow: return 500
        }
    }

    private func minimumQualityForTraining(_ kind: TrainingDatasetPipeline.DatasetKind) -> Double {
        switch kind {
        case .routing: return 0.88
        case .verification: return 0.92
        case .instructionFollowing: return 0.88
        case .workflow: return 0.90
        }
    }

    private func minimumHoldoutAccuracy(_ kind: TrainingDatasetPipeline.DatasetKind) -> Double {
        switch kind {
        case .routing: return 0.93
        case .verification: return 0.95
        case .instructionFollowing: return 0.88
        case .workflow: return 0.90
        }
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { return }
            candidates = snapshot.candidates
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, candidates: candidates)
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
}
