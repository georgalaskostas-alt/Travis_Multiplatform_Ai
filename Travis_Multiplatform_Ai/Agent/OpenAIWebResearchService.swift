import Foundation

/// OpenAI Responses API transport dedicated to grounded public-web research.
/// This is deliberately separate from AIService.generateText so ordinary chat
/// never masquerades as fresh web research.
final class OpenAIWebResearchService {
    static let shared = OpenAIWebResearchService()

    struct Result: Hashable {
        struct Source: Hashable {
            let title: String
            let url: String
        }
        let text: String
        let sources: [Source]
    }

    enum ResearchError: LocalizedError {
        case missingOpenAIKey
        case invalidResponse
        case apiError(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingOpenAIKey:
                return "Το web research απαιτεί OpenAI API key στις Ρυθμίσεις."
            case .invalidResponse:
                return "Το web research επέστρεψε μη αναμενόμενη Responses API απάντηση."
            case .apiError(let status, let message):
                return "OpenAI web research API error \(status): \(message)"
            }
        }
    }

    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func research(query: String, context: String? = nil) async throws -> Result {
        guard let key = KeychainService.shared.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw ResearchError.missingOpenAIKey
        }

        let prompt = """
        Perform current public-web research for the request below.
        Prefer primary/official sources and reputable reporting.
        Distinguish verified facts from uncertainty. Do not invent citations.
        Give a concise but substantive answer and preserve source attribution.

        REQUEST
        \(query)

        CONTEXT
        \(context ?? "None")
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "input": prompt,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "max_output_tokens": 5000,
            "reasoning": ["effort": "medium"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ResearchError.apiError(status: http.statusCode, message: Self.errorMessage(data))
        }
        return try Self.parse(data)
    }

    private static func parse(_ data: Data) throws -> Result {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResearchError.invalidResponse
        }

        var textParts: [String] = []
        var sources: [Result.Source] = []
        var seenURLs = Set<String>()

        if let convenience = json["output_text"] as? String,
           !convenience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textParts.append(convenience)
        }

        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for block in content {
                    if (block["type"] as? String) == "output_text",
                       let text = block["text"] as? String,
                       !textParts.contains(text) {
                        textParts.append(text)
                    }

                    guard let annotations = block["annotations"] as? [[String: Any]] else { continue }
                    for annotation in annotations {
                        let type = annotation["type"] as? String ?? ""
                        guard type == "url_citation" else { continue }

                        let url = (annotation["url"] as? String)
                            ?? ((annotation["url_citation"] as? [String: Any])?["url"] as? String)
                        guard let url, !url.isEmpty, !seenURLs.contains(url) else { continue }

                        let nested = annotation["url_citation"] as? [String: Any]
                        let title = (annotation["title"] as? String)
                            ?? (nested?["title"] as? String)
                            ?? URL(string: url)?.host
                            ?? "Source"
                        seenURLs.insert(url)
                        sources.append(Result.Source(title: title, url: url))
                    }
                }
            }
        }

        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResearchError.invalidResponse }
        return Result(text: text, sources: sources)
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return "Unknown API error" }
        return error["message"] as? String ?? error["type"] as? String ?? "Unknown API error"
    }
}
