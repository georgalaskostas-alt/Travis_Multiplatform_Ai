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

    private init() {}

    func generateText(prompt: String, maxTokens: Int = 1024) async throws -> String {
        guard let apiKey = KeychainService.shared.anthropicAPIKey, !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.apiError(
                status: httpResponse.statusCode,
                type: Self.errorType(from: data),
                message: Self.errorMessage(from: data)
            )
        }

        return try Self.textContent(from: data)
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
