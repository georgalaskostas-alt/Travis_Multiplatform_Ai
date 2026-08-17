import Foundation

/// Narrow contract between TRAVIS and a future local training worker.
/// The app never executes arbitrary shell commands. A backend must expose a
/// bounded localhost API and consume a previously generated immutable manifest.
@MainActor
protocol LocalTrainerBackend: AnyObject {
    var backendId: String { get }
    func health() async throws -> LocalTrainerBridge.Health
    func startTraining(manifest: LocalTrainingManifestService.Manifest) async throws -> LocalTrainerBridge.Job
    func jobStatus(id: String) async throws -> LocalTrainerBridge.Job
}

@MainActor
final class LocalTrainerBridge {
    struct Health: Codable, Hashable {
        var ready: Bool
        var backend: String
        var version: String?
        var accelerator: String?
    }

    struct Job: Codable, Hashable {
        enum State: String, Codable, Hashable {
            case queued
            case running
            case evaluating
            case completed
            case failed
            case cancelled
        }

        var id: String
        var state: State
        var progress: Double?
        var artifactLocation: String?
        var holdoutScore: Double?
        var baselineScore: Double?
        var meanLatencyMs: Double?
        var error: String?
    }

    enum BridgeError: LocalizedError {
        case invalidEndpoint
        case nonLocalEndpoint
        case unavailable
        case invalidResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "The local trainer endpoint is invalid."
            case .nonLocalEndpoint: return "For safety, the training worker endpoint must resolve to localhost/127.0.0.1."
            case .unavailable: return "The local training worker is not configured or reachable."
            case .invalidResponse(let status): return "The local training worker returned HTTP \(status)."
            }
        }
    }
}

/// Default transport for an external local worker (for example an MLX-based
/// trainer). It is intentionally localhost-only and has no cloud fallback.
@MainActor
final class LocalHTTPTrainerBackend: LocalTrainerBackend {
    let backendId = "local-http-trainer-v1"

    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    private var baseURL: URL? {
        let raw = defaults.string(forKey: "training.local.baseURL") ?? "http://127.0.0.1:8765"
        guard let url = URL(string: raw),
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return url
    }

    func health() async throws -> LocalTrainerBridge.Health {
        let request = try makeRequest(path: "/v1/health", method: "GET")
        return try await send(request, as: LocalTrainerBridge.Health.self)
    }

    func startTraining(manifest: LocalTrainingManifestService.Manifest) async throws -> LocalTrainerBridge.Job {
        var request = try makeRequest(path: "/v1/train", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.iso8601.encode(manifest)
        return try await send(request, as: LocalTrainerBridge.Job.self)
    }

    func jobStatus(id: String) async throws -> LocalTrainerBridge.Job {
        let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let request = try makeRequest(path: "/v1/jobs/\(safeId)", method: "GET")
        return try await send(request, as: LocalTrainerBridge.Job.self)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let baseURL else { throw LocalTrainerBridge.BridgeError.invalidEndpoint }
        guard let host = baseURL.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw LocalTrainerBridge.BridgeError.nonLocalEndpoint
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw LocalTrainerBridge.BridgeError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalTrainerBridge.BridgeError.unavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw LocalTrainerBridge.BridgeError.invalidResponse(http.statusCode)
        }
        return try JSONDecoder.iso8601.decode(T.self, from: data)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
