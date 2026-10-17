import Foundation

/// Stores only explicitly promoted local inference models. The AI router may
/// consult this registry, but training/evaluation never activates a model by
/// itself.
struct LocalModelRegistry {
    struct Entry: Codable, Hashable, Identifiable {
        let id: UUID
        var promotedAt: Date
        var candidateId: UUID
        var inferenceModelId: String
        var artifactLocation: String?
        var datasetKind: TrainingDatasetPipeline.DatasetKind
        var holdoutScore: Double
        var baselineScore: Double
    }

    private struct Snapshot: Codable {
        var version: Int
        var active: Entry?
        var history: [Entry]
    }

    static let shared = LocalModelRegistry()

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("local-model-registry-v1.json")
    }

    var active: Entry? { load().active }
    var activeModelId: String? { active?.inferenceModelId }

    func promote(
        candidate: LocalModelTrainingPolicy.ModelCandidate,
        inferenceModelId: String
    ) -> Bool {
        let modelId = inferenceModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty,
              candidate.stage == .candidate,
              let holdout = candidate.holdoutAccuracy,
              let baseline = candidate.baselineAccuracy else { return false }

        var snapshot = load()
        if let current = snapshot.active {
            snapshot.history.append(current)
        }
        snapshot.active = Entry(
            id: UUID(),
            promotedAt: Date(),
            candidateId: candidate.id,
            inferenceModelId: modelId,
            artifactLocation: candidate.trainingArtifactLocation,
            datasetKind: candidate.datasetKind,
            holdoutScore: holdout,
            baselineScore: baseline
        )
        if snapshot.history.count > 20 {
            snapshot.history.removeFirst(snapshot.history.count - 20)
        }
        return save(snapshot)
    }

    @discardableResult
    func rollback() -> Entry? {
        var snapshot = load()
        guard let previous = snapshot.history.popLast() else { return nil }
        snapshot.active = previous
        return save(snapshot) ? previous : nil
    }

    func diagnosticReport() -> String {
        let snapshot = load()
        let activeText: String
        if let active = snapshot.active {
            activeText = "\(active.inferenceModelId) — kind=\(active.datasetKind.rawValue), holdout=\(String(format: "%.3f", active.holdoutScore)), baseline=\(String(format: "%.3f", active.baselineScore))"
        } else {
            activeText = "κανένα"
        }
        return """
        TRAVIS LOCAL MODEL REGISTRY

        ACTIVE PROMOTED MODEL
        \(activeText)

        ROLLBACK HISTORY
        \(snapshot.history.count)
        """
    }

    private func load() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return Snapshot(version: 1, active: nil, history: [])
        }
        return snapshot
    }

    private func save(_ snapshot: Snapshot) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }
}
