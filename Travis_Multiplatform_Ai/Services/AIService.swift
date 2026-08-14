import Foundation

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(status: Int, type: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Δεν έχει οριστεί Anthropic API key. Πρόσθεσέ το στις Ρυθμίσεις."
        case .invalidResponse:
            return "Μη αναμενόμενη απάντηση από το Anthropic API."
        case .apiError(let status, let type, let message):
            return "Anthropic API error \(status) (\(type)): \(message)"
        }
    }
}

final class AIService {
    static let shared = AIService()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    private let model = "claude-sonnet-4-6"
    private let maxAttempts = 3

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private init() {}

    func generateText(prompt: String, maxTokens: Int = 1024) async throws -> String {
        guard let apiKey = KeychainService.shared.anthropicAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIServiceError.invalidResponse
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return try Self.textContent(from: data)
                }

                let apiError = AIServiceError.apiError(
                    status: httpResponse.statusCode,
                    type: Self.errorType(from: data),
                    message: Self.errorMessage(from: data)
                )

                guard Self.isRetryableHTTPStatus(httpResponse.statusCode),
                      attempt < maxAttempts
                else {
                    throw apiError
                }

                lastError = apiError
                try await Self.backoff(afterAttempt: attempt)
            } catch let urlError as URLError {
                guard Self.isRetryable(urlError),
                      attempt < maxAttempts
                else {
                    throw urlError
                }

                lastError = urlError
                try await Self.backoff(afterAttempt: attempt)
            } catch {
                throw error
            }
        }

        throw lastError ?? AIServiceError.invalidResponse
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    private static func backoff(afterAttempt attempt: Int) async throws {
        let seconds = min(pow(2.0, Double(attempt - 1)), 8.0)
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func textContent(from data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw AIServiceError.invalidResponse
        }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard !text.isEmpty else { throw AIServiceError.invalidResponse }
        return text
    }

    private static func errorType(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "unknown_error" }
        return error["type"] as? String ?? "unknown_error"
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "" }
        return error["message"] as? String ?? ""
    }
}
