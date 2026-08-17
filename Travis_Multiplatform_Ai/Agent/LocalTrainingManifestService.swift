import Foundation
import CryptoKit

@MainActor
final class LocalTrainingManifestService {
    static let shared = LocalTrainingManifestService()

    struct JSONLRecord: Codable, Hashable {
        var input: String
        var target: String
        var kind: String
        var capabilityId: String?
        var qualityScore: Double
    }

    struct Manifest: Identifiable, Codable, Hashable {
        let id: UUID
        var createdAt: Date
        var datasetKind: TrainingDatasetPipeline.DatasetKind
        var baseModel: String
        var trainingCount: Int
        var validationCount: Int
        var minimumQuality: Double
        var datasetSHA256: String
        var trainFile: String
        var validationFile: String
        var targetMetric: String
        var minimumTargetScore: Double
    }

    enum ExportError: LocalizedError {
        case notEligible(String)
        case emptyBaseModel
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .notEligible(let reason): return "Training dataset is not eligible: \(reason)"
            case .emptyBaseModel: return "A concrete local base-model identifier is required."
            case .encodingFailed: return "Could not encode the training dataset."
            }
        }
    }

    /// Creates an immutable train/validation export under Application Support.
    /// No network upload or model training happens here.
    func prepareExport(
        kind: TrainingDatasetPipeline.DatasetKind,
        baseModel: String,
        validationFraction: Double = 0.15
    ) throws -> Manifest {
        let baseModel = baseModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModel.isEmpty else { throw ExportError.emptyBaseModel }

        let eligibility = LocalModelTrainingPolicy.shared.eligibility(for: kind)
        guard eligibility.eligible else { throw ExportError.notEligible(eligibility.reason) }

        let source = TrainingDatasetPipeline.shared.exportableExamples(
            kind: kind,
            minimumQuality: eligibility.minimumQuality,
            limit: 10_000
        )
        let stable = source.sorted {
            if $0.sourceTaskId != $1.sourceTaskId {
                return $0.sourceTaskId.uuidString < $1.sourceTaskId.uuidString
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        // Split by source task rather than by individual row to reduce leakage
        // between training and validation examples from the same task.
        let grouped = Dictionary(grouping: stable, by: \.sourceTaskId)
        let taskIds = grouped.keys.sorted { $0.uuidString < $1.uuidString }
        let requestedValidation = max(1, Int((Double(taskIds.count) * min(max(validationFraction, 0.05), 0.30)).rounded()))
        let validationIds = Set(taskIds.suffix(requestedValidation))

        let validationExamples = stable.filter { validationIds.contains($0.sourceTaskId) }
        let trainingExamples = stable.filter { !validationIds.contains($0.sourceTaskId) }
        guard !trainingExamples.isEmpty, !validationExamples.isEmpty else {
            throw ExportError.notEligible("Not enough independent source tasks for a leakage-resistant train/validation split.")
        }

        let trainData = try encodeJSONL(trainingExamples)
        let validationData = try encodeJSONL(validationExamples)
        let combinedHash = SHA256.hash(data: trainData + validationData)
            .map { String(format: "%02x", $0) }
            .joined()

        let root = trainingDirectory()
        let exportId = UUID()
        let exportDirectory = root.appendingPathComponent(exportId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let trainURL = exportDirectory.appendingPathComponent("train.jsonl")
        let validationURL = exportDirectory.appendingPathComponent("validation.jsonl")
        try trainData.write(to: trainURL, options: .atomic)
        try validationData.write(to: validationURL, options: .atomic)

        let manifest = Manifest(
            id: exportId,
            createdAt: Date(),
            datasetKind: kind,
            baseModel: baseModel,
            trainingCount: trainingExamples.count,
            validationCount: validationExamples.count,
            minimumQuality: eligibility.minimumQuality,
            datasetSHA256: combinedHash,
            trainFile: trainURL.path,
            validationFile: validationURL.path,
            targetMetric: targetMetric(for: kind),
            minimumTargetScore: minimumScore(for: kind)
        )

        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: exportDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    private func encodeJSONL(_ examples: [TrainingDatasetPipeline.TrainingExample]) throws -> Data {
        var output = Data()
        let encoder = JSONEncoder()
        for example in examples {
            let record = JSONLRecord(
                input: example.input,
                target: example.target,
                kind: example.kind.rawValue,
                capabilityId: example.capabilityId,
                qualityScore: example.qualityScore
            )
            guard let newline = "\n".data(using: .utf8) else { throw ExportError.encodingFailed }
            output.append(try encoder.encode(record))
            output.append(newline)
        }
        return output
    }

    private func trainingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("TRAVIS/TrainingExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func targetMetric(for kind: TrainingDatasetPipeline.DatasetKind) -> String {
        switch kind {
        case .routing: return "accuracy"
        case .verification: return "verdict_accuracy"
        case .instructionFollowing: return "task_success_rate"
        case .workflow: return "workflow_exact_or_semantic_match"
        }
    }

    private func minimumScore(for kind: TrainingDatasetPipeline.DatasetKind) -> Double {
        switch kind {
        case .routing: return 0.93
        case .verification: return 0.95
        case .instructionFollowing: return 0.88
        case .workflow: return 0.90
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
