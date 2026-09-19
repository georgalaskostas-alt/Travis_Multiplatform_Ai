import Foundation

enum AIProvider: String, Codable, CaseIterable, Hashable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case openRouter = "OpenRouter"
    case local = "Local"
}

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case noConfiguredProvider
    case invalidResponse(provider: AIProvider)
    case apiError(provider: AIProvider, status: Int, type: String, message: String)
    case allProvidersFailed([String])

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Δεν έχει οριστεί διαθέσιμο AI provider credential."
        case .noConfiguredProvider:
            return "Δεν υπάρχει διαθέσιμο AI provider/model για αυτό το workload."
        case .invalidResponse(let provider):
            return "Μη αναμενόμενη απάντηση από το \(provider.rawValue) API."
        case .apiError(let provider, let status, let type, let message):
            return "\(provider.rawValue) API error \(status) (\(type)): \(message)"
        case .allProvidersFailed(let failures):
            return "Όλοι οι διαθέσιμοι AI providers απέτυχαν: \(failures.joined(separator: " | "))"
        }
    }
}

/// Central provider-neutral AI gateway for TRAVIS.
///
/// Responsibilities:
/// - build a cost-aware progressive provider chain via AIModelRouter
/// - enforce task AI budgets before every network call
/// - execute OpenAI / Anthropic / OpenRouter / local OpenAI-compatible providers
/// - record provider-reported token usage, retries and latency
///
/// Capabilities never choose providers directly.
final class AIService {
    static let shared = AIService()

    private let openAIEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let anthropicAPIVersion = "2023-06-01"
    private let maxAttempts = 3
    private let modelRouter = AIModelRouter()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private init() {}

    func generateText(
        prompt: String,
        maxTokens: Int = 1024,
        context: AIInvocationContext = .general
    ) async throws -> String {
        let openAIKey = Self.normalized(KeychainService.shared.openAIAPIKey)
        let anthropicKey = Self.normalized(KeychainService.shared.anthropicAPIKey)
        let openRouterKey = Self.normalized(KeychainService.shared.openRouterAPIKey)
        let preferences = AIProviderPreferences()

        let availability = AIProviderAvailability(
            hasOpenAI: openAIKey != nil,
            hasAnthropic: anthropicKey != nil,
            hasOpenRouter: openRouterKey != nil,
            localBaseURL: preferences.localBaseURL,
            localModel: preferences.localModel,
            preferences: preferences
        )

        let candidates = modelRouter.candidates(
            for: prompt,
            context: context,
            availability: availability
        )
        guard !candidates.isEmpty else { throw AIServiceError.noConfiguredProvider }

        var failures: [String] = []

        for selection in candidates {
            do {
                try await enforceBudget(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    selection: selection,
                    context: context
                )

                return try await generate(
                    selection: selection,
                    prompt: prompt,
                    maxTokens: maxTokens,
                    context: context,
                    openAIKey: openAIKey,
                    anthropicKey: anthropicKey,
                    openRouterKey: openRouterKey,
                    localBaseURL: preferences.localBaseURL
                )
            } catch let budgetError as AIBudgetGuard.BudgetError {
                // Budget rejection is policy, not provider failure. Never
                // escalate to a more expensive provider after this point.
                throw budgetError
            } catch {
                failures.append("\(selection.provider.rawValue)/\(selection.model): \(error.localizedDescription)")
                continue
            }
        }

        throw AIServiceError.allProvidersFailed(failures)
    }

    private func enforceBudget(
        prompt: String,
        maxTokens: Int,
        selection: AIModelSelection,
        context: AIInvocationContext
    ) async throws {
        try await MainActor.run {
            try AIBudgetGuard().preflight(
                prompt: prompt,
                maxOutputTokens: maxTokens,
                selection: selection,
                context: context
            )
        }
    }

    private func generate(
        selection: AIModelSelection,
        prompt: String,
        maxTokens: Int,
        context: AIInvocationContext,
        openAIKey: String?,
        anthropicKey: String?,
        openRouterKey: String?,
        localBaseURL: URL?
    ) async throws -> String {
        switch selection.provider {
        case .openAI:
            guard let key = openAIKey else { throw AIServiceError.missingAPIKey }
            return try await generateWithOpenAI(
                selection: selection,
                prompt: prompt,
                maxTokens: maxTokens,
                apiKey: key,
                context: context
            )

        case .anthropic:
            guard let key = anthropicKey else { throw AIServiceError.missingAPIKey }
            return try await generateWithAnthropic(
                selection: selection,
                prompt: prompt,
                maxTokens: maxTokens,
                apiKey: key,
                context: context
            )

        case .openRouter:
            guard let key = openRouterKey else { throw AIServiceError.missingAPIKey }
            return try await generateOpenAICompatible(
                endpoint: openRouterEndpoint,
                selection: selection,
                prompt: prompt,
                maxTokens: maxTokens,
                bearerToken: key,
                context: context
            )

        case .local:
            guard let baseURL = localBaseURL else { throw AIServiceError.noConfiguredProvider }
            let endpoint = Self.localChatCompletionsEndpoint(baseURL)
            return try await generateOpenAICompatible(
                endpoint: endpoint,
                selection: selection,
                prompt: prompt,
                maxTokens: maxTokens,
                bearerToken: nil,
                context: context
            )
        }
    }

    // MARK: - OpenAI Responses API

    private func generateWithOpenAI(
        selection: AIModelSelection,
        prompt: String,
        maxTokens: Int,
        apiKey: String,
        context: AIInvocationContext
    ) async throws -> String {
        var request = URLRequest(url: openAIEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": selection.model,
            "input": prompt,
            "max_output_tokens": maxTokens
        ]
        if let effort = selection.reasoningEffort {
            body["reasoning"] = ["effort": effort]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(
            request: request,
            selection: selection,
            context: context,
            textParser: Self.openAITextContent,
            usageParser: Self.openAIUsage,
            errorTypeParser: Self.openAIErrorType,
            errorMessageParser: Self.openAIErrorMessage
        )
    }

    private static func openAITextContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.invalidResponse(provider: .openAI)
        }

        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for block in content {
                    if (block["type"] as? String) == "output_text",
                       let text = block["text"] as? String {
                        parts.append(text)
                    }
                }
            }
            let text = parts.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }

        throw AIServiceError.invalidResponse(provider: .openAI)
    }

    private static func openAIUsage(from data: Data) -> AITokenUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return AITokenUsage() }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let outputDetails = usage["output_tokens_details"] as? [String: Any]

        return AITokenUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: inputDetails?["cached_tokens"] as? Int ?? 0,
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int ?? 0
        )
    }

    private static func openAIErrorType(from data: Data) -> String {
        genericErrorType(data)
    }

    private static func openAIErrorMessage(from data: Data) -> String {
        genericErrorMessage(data)
    }

    // MARK: - Anthropic Messages API

    private func generateWithAnthropic(
        selection: AIModelSelection,
        prompt: String,
        maxTokens: Int,
        apiKey: String,
        context: AIInvocationContext
    ) async throws -> String {
        var request = URLRequest(url: anthropicEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": selection.model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(
            request: request,
            selection: selection,
            context: context,
            textParser: Self.anthropicTextContent,
            usageParser: Self.anthropicUsage,
            errorTypeParser: Self.anthropicErrorType,
            errorMessageParser: Self.anthropicErrorMessage
        )
    }

    private static func anthropicTextContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIServiceError.invalidResponse(provider: .anthropic)
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIServiceError.invalidResponse(provider: .anthropic) }
        return text
    }

    private static func anthropicUsage(from data: Data) -> AITokenUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return AITokenUsage() }
        return AITokenUsage(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cachedInputTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    private static func anthropicErrorType(from data: Data) -> String { genericErrorType(data) }
    private static func anthropicErrorMessage(from data: Data) -> String { genericErrorMessage(data) }

    // MARK: - OpenAI-compatible providers (OpenRouter / local)

    private func generateOpenAICompatible(
        endpoint: URL,
        selection: AIModelSelection,
        prompt: String,
        maxTokens: Int,
        bearerToken: String?,
        context: AIInvocationContext
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": selection.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens
        ]
        if let effort = selection.reasoningEffort, selection.provider == .openRouter {
            body["reasoning"] = ["effort": effort]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(
            request: request,
            selection: selection,
            context: context,
            textParser: { data in
                try Self.chatCompletionsText(from: data, provider: selection.provider)
            },
            usageParser: Self.chatCompletionsUsage,
            errorTypeParser: Self.genericErrorType,
            errorMessageParser: Self.genericErrorMessage
        )
    }

    private static func chatCompletionsText(from data: Data, provider: AIProvider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIServiceError.invalidResponse(provider: provider)
        }

        if let text = message["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }

        throw AIServiceError.invalidResponse(provider: provider)
    }

    private static func chatCompletionsUsage(from data: Data) -> AITokenUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return AITokenUsage() }

        let promptTokens = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int ?? 0
        let completionTokens = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int ?? 0
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]

        return AITokenUsage(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
            cachedInputTokens: promptDetails?["cached_tokens"] as? Int ?? 0,
            reasoningTokens: completionDetails?["reasoning_tokens"] as? Int ?? 0
        )
    }

    // MARK: - Shared transport

    private func perform(
        request: URLRequest,
        selection: AIModelSelection,
        context: AIInvocationContext,
        textParser: (Data) throws -> String,
        usageParser: (Data) -> AITokenUsage,
        errorTypeParser: (Data) -> String,
        errorMessageParser: (Data) -> String
    ) async throws -> String {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            let started = ContinuousClock.now
            do {
                let (data, response) = try await session.data(for: request)
                let latency = Self.milliseconds(started.duration(to: .now))

                guard let httpResponse = response as? HTTPURLResponse else {
                    await recordUsage(
                        selection: selection,
                        context: context,
                        usage: AITokenUsage(),
                        latency: latency,
                        attempt: attempt,
                        succeeded: false,
                        errorType: "invalid_response"
                    )
                    throw AIServiceError.invalidResponse(provider: selection.provider)
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    let usage = usageParser(data)
                    let text = try textParser(data)
                    await recordUsage(
                        selection: selection,
                        context: context,
                        usage: usage,
                        latency: latency,
                        attempt: attempt,
                        succeeded: true,
                        errorType: nil
                    )
                    return text
                }

                let errorType = errorTypeParser(data)
                let apiError = AIServiceError.apiError(
                    provider: selection.provider,
                    status: httpResponse.statusCode,
                    type: errorType,
                    message: errorMessageParser(data)
                )
                await recordUsage(
                    selection: selection,
                    context: context,
                    usage: usageParser(data),
                    latency: latency,
                    attempt: attempt,
                    succeeded: false,
                    errorType: errorType
                )

                guard Self.isRetryableHTTPStatus(httpResponse.statusCode), attempt < maxAttempts else {
                    throw apiError
                }
                lastError = apiError
                try await Self.backoff(afterAttempt: attempt)
            } catch let urlError as URLError {
                let latency = Self.milliseconds(started.duration(to: .now))
                await recordUsage(
                    selection: selection,
                    context: context,
                    usage: AITokenUsage(),
                    latency: latency,
                    attempt: attempt,
                    succeeded: false,
                    errorType: "url_\(urlError.code.rawValue)"
                )
                guard Self.isRetryable(urlError), attempt < maxAttempts else { throw urlError }
                lastError = urlError
                try await Self.backoff(afterAttempt: attempt)
            } catch {
                throw error
            }
        }

        throw lastError ?? AIServiceError.invalidResponse(provider: selection.provider)
    }

    private func recordUsage(
        selection: AIModelSelection,
        context: AIInvocationContext,
        usage: AITokenUsage,
        latency: Int,
        attempt: Int,
        succeeded: Bool,
        errorType: String?
    ) async {
        await MainActor.run {
            AIUsageLedger.shared.record(
                selection: selection,
                context: context,
                usage: usage,
                latencyMilliseconds: latency,
                attempt: attempt,
                succeeded: succeeded,
                errorType: errorType
            )
        }
    }

    private static func genericErrorType(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unknown_error"
        }
        if let error = json["error"] as? [String: Any] {
            return error["type"] as? String ?? error["code"] as? String ?? "unknown_error"
        }
        return json["type"] as? String ?? "unknown_error"
    }

    private static func genericErrorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? ""
        }
        return json["message"] as? String ?? ""
    }

    private static func localChatCompletionsEndpoint(_ baseURL: URL) -> URL {
        let normalized = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/chat/completions") { return URL(string: normalized) ?? baseURL }
        if normalized.hasSuffix("/v1") {
            return URL(string: normalized + "/chat/completions") ?? baseURL
        }
        return URL(string: normalized + "/v1/chat/completions") ?? baseURL
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        switch status {
        case 408, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }

    private static func backoff(afterAttempt attempt: Int) async throws {
        let seconds = min(pow(2.0, Double(attempt - 1)), 8.0)
        try await Task.sleep(for: .seconds(seconds))
    }
}
