import Foundation

enum AIProvider: String {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
}

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse(provider: AIProvider)
    case apiError(provider: AIProvider, status: Int, type: String, message: String)
    case allProvidersFailed(primary: String, fallback: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Δεν έχει οριστεί OpenAI ή Anthropic API key. Πρόσθεσε τουλάχιστον ένα στις Ρυθμίσεις."
        case .invalidResponse(let provider):
            return "Μη αναμενόμενη απάντηση από το \(provider.rawValue) API."
        case .apiError(let provider, let status, let type, let message):
            return "\(provider.rawValue) API error \(status) (\(type)): \(message)"
        case .allProvidersFailed(let primary, let fallback):
            if let fallback {
                return "Όλοι οι AI providers απέτυχαν. Primary: \(primary) | Fallback: \(fallback)"
            }
            return "Ο AI provider απέτυχε: \(primary)"
        }
    }
}

/// Central AI transport/router for TRAVIS.
///
/// Provider order:
///   1. OpenAI Responses API (primary, when key exists)
///   2. Anthropic Messages API (fallback, when key exists)
///
/// The public API intentionally remains `generateText(prompt:maxTokens:)` so
/// planner, verifier, repository grounding and capabilities do not need to
/// know which provider/model is serving a request.
final class AIService {
    static let shared = AIService()

    private let openAIEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicAPIVersion = "2023-06-01"
    private let anthropicModel = "claude-sonnet-4-6"
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
        let openAIKey = KeychainService.shared.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let anthropicKey = KeychainService.shared.anthropicAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasOpenAI = !(openAIKey ?? "").isEmpty
        let hasAnthropic = !(anthropicKey ?? "").isEmpty

        guard hasOpenAI || hasAnthropic else {
            throw AIServiceError.missingAPIKey
        }

        var primaryFailure: Error?

        if let openAIKey, !openAIKey.isEmpty {
            do {
                return try await generateWithOpenAI(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    apiKey: openAIKey
                )
            } catch {
                primaryFailure = error

                // Do not fail the autonomous runtime immediately when a
                // second configured provider can continue the task.
                guard let anthropicKey, !anthropicKey.isEmpty else {
                    throw error
                }
            }
        }

        if let anthropicKey, !anthropicKey.isEmpty {
            do {
                return try await generateWithAnthropic(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    apiKey: anthropicKey
                )
            } catch {
                throw AIServiceError.allProvidersFailed(
                    primary: primaryFailure?.localizedDescription ?? "OpenAI unavailable/not configured",
                    fallback: error.localizedDescription
                )
            }
        }

        throw primaryFailure ?? AIServiceError.missingAPIKey
    }

    // MARK: - OpenAI Primary

    private func generateWithOpenAI(
        prompt: String,
        maxTokens: Int,
        apiKey: String
    ) async throws -> String {
        let model = Self.openAIModel(for: prompt)

        var request = URLRequest(url: openAIEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "input": prompt,
            "max_output_tokens": maxTokens,
            "reasoning": [
                "effort": Self.openAIReasoningEffort(for: prompt)
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(
            request: request,
            provider: .openAI,
            textParser: Self.openAITextContent,
            errorTypeParser: Self.openAIErrorType,
            errorMessageParser: Self.openAIErrorMessage
        )
    }

    /// Cost-aware model routing.
    /// - Planner/repository/source-code work gets Terra.
    /// - Verification/routine conversational work gets Luna.
    private static func openAIModel(for prompt: String) -> String {
        let value = prompt.lowercased()
        let complexMarkers = [
            "planning component",
            "repository-analysis component",
            "repository tree",
            "selected source files",
            "source code",
            "architecture",
            "autonomous runtime",
            "taskplanner"
        ]

        return complexMarkers.contains(where: value.contains)
            ? "gpt-5.6-terra"
            : "gpt-5.6-luna"
    }

    private static func openAIReasoningEffort(for prompt: String) -> String {
        let value = prompt.lowercased()
        if value.contains("repository-analysis component")
            || value.contains("planning component")
            || value.contains("architecture") {
            return "medium"
        }
        return "low"
    }

    private static func openAITextContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.invalidResponse(provider: .openAI)
        }

        // Some Responses API representations expose a convenience output_text.
        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        // Canonical Responses API shape: output[] -> message -> content[] -> output_text.text
        if let output = json["output"] as? [[String: Any]] {
            var parts: [String] = []

            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for block in content {
                    let type = block["type"] as? String
                    if type == "output_text", let text = block["text"] as? String {
                        parts.append(text)
                    }
                }
            }

            let text = parts.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        throw AIServiceError.invalidResponse(provider: .openAI)
    }

    private static func openAIErrorType(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "unknown_error" }

        return error["type"] as? String
            ?? error["code"] as? String
            ?? "unknown_error"
    }

    private static func openAIErrorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "" }

        return error["message"] as? String ?? ""
    }

    // MARK: - Anthropic Fallback

    private func generateWithAnthropic(
        prompt: String,
        maxTokens: Int,
        apiKey: String
    ) async throws -> String {
        var request = URLRequest(url: anthropicEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": anthropicModel,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(
            request: request,
            provider: .anthropic,
            textParser: Self.anthropicTextContent,
            errorTypeParser: Self.anthropicErrorType,
            errorMessageParser: Self.anthropicErrorMessage
        )
    }

    // MARK: - Shared Transport

    private func perform(
        request: URLRequest,
        provider: AIProvider,
        textParser: (Data) throws -> String,
        errorTypeParser: (Data) -> String,
        errorMessageParser: (Data) -> String
    ) async throws -> String {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIServiceError.invalidResponse(provider: provider)
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return try textParser(data)
                }

                let apiError = AIServiceError.apiError(
                    provider: provider,
                    status: httpResponse.statusCode,
                    type: errorTypeParser(data),
                    message: errorMessageParser(data)
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

        throw lastError ?? AIServiceError.invalidResponse(provider: provider)
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

    private static func anthropicTextContent(from data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw AIServiceError.invalidResponse(provider: .anthropic)
        }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard !text.isEmpty else {
            throw AIServiceError.invalidResponse(provider: .anthropic)
        }
        return text
    }

    private static func anthropicErrorType(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "unknown_error" }
        return error["type"] as? String ?? "unknown_error"
    }

    private static func anthropicErrorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return "" }
        return error["message"] as? String ?? ""
    }
}
