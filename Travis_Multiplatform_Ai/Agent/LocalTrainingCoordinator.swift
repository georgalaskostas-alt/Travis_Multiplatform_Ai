import Foundation
import Observation

@MainActor
@Observable
final class LocalTrainingCoordinator {
    static let shared = LocalTrainingCoordinator()

    struct ActiveRun: Identifiable, Hashable {
        let id: UUID
        var candidateId: UUID
        var manifestId: UUID
        var backendJobId: String
        var state: LocalTrainerBridge.Job.State
        var progress: Double?
        var lastUpdatedAt: Date
    }

    private(set) var activeRuns: [ActiveRun] = []
    private(set) var lastError: String?

    private let policy: LocalModelTrainingPolicy
    private let manifestService: LocalTrainingManifestService
    private let backend: LocalTrainerBackend

    init(
        policy: LocalModelTrainingPolicy = .shared,
        manifestService: LocalTrainingManifestService = .shared,
        backend: LocalTrainerBackend = LocalHTTPTrainerBackend()
    ) {
        self.policy = policy
        self.manifestService = manifestService
        self.backend = backend
    }

    @discardableResult
    func start(
        name: String,
        kind: TrainingDatasetPipeline.DatasetKind,
        baseModel: String
    ) async throws -> ActiveRun {
        let health = try await backend.health()
        guard health.ready else { throw LocalTrainerBridge.BridgeError.unavailable }

        guard let candidate = policy.registerTrainingCandidate(name: name, kind: kind) else {
            let eligibility = policy.eligibility(for: kind)
            throw LocalTrainingCoordinatorError.datasetNotEligible(eligibility.reason)
        }

        let manifest = try manifestService.prepareExport(kind: kind, baseModel: baseModel)
        let job = try await backend.startTraining(manifest: manifest)
        let run = ActiveRun(
            id: UUID(),
            candidateId: candidate.id,
            manifestId: manifest.id,
            backendJobId: job.id,
            state: job.state,
            progress: job.progress,
            lastUpdatedAt: Date()
        )
        activeRuns.append(run)
        lastError = nil
        return run
    }

    func refresh(runId: UUID) async throws -> ActiveRun? {
        guard let index = activeRuns.firstIndex(where: { $0.id == runId }) else { return nil }
        let job = try await backend.jobStatus(id: activeRuns[index].backendJobId)
        activeRuns[index].state = job.state
        activeRuns[index].progress = job.progress
        activeRuns[index].lastUpdatedAt = Date()

        if job.state == .completed,
           let holdout = job.holdoutScore,
           let baseline = job.baselineScore,
           let latency = job.meanLatencyMs {
            policy.recordEvaluation(
                candidateId: activeRuns[index].candidateId,
                holdoutAccuracy: holdout,
                baselineAccuracy: baseline,
                meanLatencyMs: latency,
                artifactLocation: job.artifactLocation
            )
        } else if job.state == .failed {
            policy.rollback(
                candidateId: activeRuns[index].candidateId,
                reason: job.error ?? "Local trainer reported failure."
            )
            lastError = job.error
        }

        return activeRuns[index]
    }

    func diagnosticReport() -> String {
        let rows = activeRuns.suffix(10).map { run in
            let progress = run.progress.map { " \(Int(min(max($0, 0), 1) * 100))%" } ?? ""
            return "\(run.backendJobId) [\(run.state.rawValue)]\(progress) candidate=\(String(run.candidateId.uuidString.prefix(8)))"
        }.joined(separator: "\n")

        return """
        TRAVIS LOCAL TRAINING COORDINATOR

        BACKEND
        \(backend.backendId)

        ACTIVE / RECENT RUNS
        \(rows.isEmpty ? "κανένα" : rows)

        LAST ERROR
        \(lastError ?? "κανένα")
        """
    }
}

private enum LocalTrainingCoordinatorError: LocalizedError {
    case datasetNotEligible(String)

    var errorDescription: String? {
        switch self {
        case .datasetNotEligible(let reason): return "Local training cannot start yet: \(reason)"
        }
    }
}
