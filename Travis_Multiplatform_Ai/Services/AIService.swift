import Foundation

final class AIService {
    static let shared = AIService()

    private init() {}

    func summarize(text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Δεν δόθηκε κείμενο." }
        return "Σύνοψη: \(trimmed.prefix(120))"
    }

    func fetchWebContext(for query: String) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://duckduckgo.com/?q=\(encoded)")!

        let (_, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse {
            return "Έγινε web request για '\(query)' με status \(httpResponse.statusCode)."
        } else {
            return "Έγινε web request για '\(query)'."
        }
    }

    func answerInGreek(_ prompt: String) async -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Δεν έλαβα ερώτηση." }

        return "Ελληνική απάντηση για: \(trimmed)"
    }
}
