import Foundation

struct GitHubFileSnapshot: Hashable {
    let path: String
    let sha: String
    let content: String
}

enum GitHubCodingServiceError: LocalizedError {
    case missingToken
    case invalidURL
    case invalidResponse
    case http(status: Int, message: String)
    case nonTextFile

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Δεν υπάρχει GitHub token στις Ρυθμίσεις."
        case .invalidURL: return "Μη έγκυρο GitHub API URL."
        case .invalidResponse: return "Μη αναμενόμενη απάντηση από το GitHub API."
        case .http(let status, let message): return "GitHub API HTTP \(status): \(message)"
        case .nonTextFile: return "Το GitHub αρχείο δεν αποκωδικοποιήθηκε ως UTF-8 text."
        }
    }
}

/// Low-level transport for TRAVIS's own repository. Reads are safe and can be
/// anonymous for public repositories. Writes require an explicit GitHub token
/// and are only called from an approved ProposedAction resolution path.
final class GitHubCodingService {
    static let shared = GitHubCodingService()

    let repository = "georgalaskostas-alt/Travis_Multiplatform_Ai"
    let branch = "agent/travis-runtime-v1"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchFile(path: String) async throws -> GitHubFileSnapshot {
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard var components = URLComponents(string: "https://api.github.com/repos/\(repository)/contents/\(encodedPath)") else {
            throw GitHubCodingServiceError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components.url else { throw GitHubCodingServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = KeychainService.shared.githubToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = object["sha"] as? String,
              let encoded = object["content"] as? String else {
            throw GitHubCodingServiceError.invalidResponse
        }

        let compact = encoded.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: compact),
              let text = String(data: decoded, encoding: .utf8) else {
            throw GitHubCodingServiceError.nonTextFile
        }
        return GitHubFileSnapshot(path: path, sha: sha, content: text)
    }

    @discardableResult
    func replaceFile(
        path: String,
        expectedSHA: String,
        newContent: String,
        commitMessage: String
    ) async throws -> String {
        guard let token = KeychainService.shared.githubToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw GitHubCodingServiceError.missingToken
        }

        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/contents/\(encodedPath)") else {
            throw GitHubCodingServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "message": String(commitMessage.prefix(180)),
            "content": Data(newContent.utf8).base64EncodedString(),
            "sha": expectedSHA,
            "branch": branch
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = object["commit"] as? [String: Any],
              let sha = commit["sha"] as? String else {
            throw GitHubCodingServiceError.invalidResponse
        }
        return sha
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubCodingServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["message"] as? String {
                message = value
            } else {
                message = String(data: data, encoding: .utf8) ?? "unknown error"
            }
            throw GitHubCodingServiceError.http(status: http.statusCode, message: message)
        }
    }
}
