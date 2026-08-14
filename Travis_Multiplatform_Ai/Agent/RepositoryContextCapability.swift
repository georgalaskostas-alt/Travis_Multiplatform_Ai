import Foundation

@MainActor
final class RepositoryContextCapability: AgentCapability {
    let id = "repository_context"
    let name = "Repository Context"
    let capabilityDescription =
        "Read-only ανάλυση του πραγματικού GitHub repository και source code του TRAVIS."

    let keywords = [
        "repository", "repo", "codebase", "source code",
        "architecture", "runtime", "κώδικ", "αρχιτεκτον",
        "project travis", "travis project"
    ]

    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService
    private let repositoryService: GitHubRepositoryContextService

    init(
        aiService: AIService = .shared,
        repositoryService: GitHubRepositoryContextService = GitHubRepositoryContextService()
    ) {
        self.aiService = aiService
        self.repositoryService = repositoryService
    }

    func handle(
        command: String,
        recentHistory: [ChatMessage]
    ) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let snapshot = try await repositoryService.context(for: command)

        let prompt = """
        You are the repository-analysis component of TRAVIS.

        TASK:
        \(command)

        REPOSITORY:
        \(snapshot.repository)

        BRANCH:
        \(snapshot.branch)

        GROUNDING RULES:
        - Analyze only the repository evidence supplied below.
        - Do not claim you inspected files that are not included.
        - Do not invent types, APIs, persistence, workers, tests, behavior, or capabilities.
        - Clearly separate verified observations from recommendations.
        - This capability is read-only. Do not claim code was modified.
        - You do not have access to local uncommitted changes.
        - For every important finding, cite at least one concrete source path from the supplied files.
        - Prefer evidence-backed findings over generic autonomous-agent advice.

        REPOSITORY TREE:
        \(snapshot.tree)

        SELECTED SOURCE FILES:
        \(snapshot.sources)

        Produce the requested technical analysis.
        """

        let result = try await aiService.generateText(
            prompt: prompt,
            maxTokens: 5000
        )

        return .reply(result)
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability. It never produces state-changing proposals.
    }
}

struct RepositoryContextSnapshot {
    let repository: String
    let branch: String
    let tree: String
    let sources: String
}

final class GitHubRepositoryContextService {
    private let owner: String
    private let repository: String
    private let branch: String
    private let session: URLSession

    private let maxSelectedFiles = 12
    private let maxCharactersPerFile = 12_000
    private let maxTotalSourceCharacters = 80_000

    init(
        owner: String = "georgalaskostas-alt",
        repository: String = "Travis_Multiplatform_Ai",
        branch: String = "agent/travis-runtime-v1"
    ) {
        self.owner = owner
        self.repository = repository
        self.branch = branch

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func context(for task: String) async throws -> RepositoryContextSnapshot {
        let paths = try await fetchSwiftPaths()
        let selected = select(paths: paths, task: task)

        var chunks: [String] = []
        var totalCharacters = 0

        for path in selected {
            guard totalCharacters < maxTotalSourceCharacters else {
                break
            }

            guard let text = try? await fetchFile(path: path) else {
                continue
            }

            let remaining = maxTotalSourceCharacters - totalCharacters
            let allowed = min(maxCharactersPerFile, remaining)
            let clipped = String(text.prefix(allowed))

            let truncationNotice =
                text.count > clipped.count
                ? "\n[FILE TRUNCATED BY REPOSITORY CONTEXT BUDGET]"
                : ""

            chunks.append(
                """
                ===== FILE: \(path) =====
                \(clipped)\(truncationNotice)
                """
            )

            totalCharacters += clipped.count
        }

        guard !chunks.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        let tree = paths
            .sorted()
            .prefix(220)
            .joined(separator: "\n")

        return RepositoryContextSnapshot(
            repository: "\(owner)/\(repository)",
            branch: branch,
            tree: tree,
            sources: chunks.joined(separator: "\n\n")
        )
    }

    private func fetchSwiftPaths() async throws -> [String] {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )

        let encodedBranch = branch.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) ?? branch

        guard let url = URL(
            string:
                "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(encodedBranch)?recursive=1"
        ) else {
            throw URLError(.badURL)
        }

        let data = try await request(url)
        let tree = try JSONDecoder().decode(
            GitHubTreeResponse.self,
            from: data
        )

        return tree.tree
            .filter {
                $0.type == "blob" && $0.path.hasSuffix(".swift")
            }
            .map(\.path)
    }

    private func fetchFile(path: String) async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path =
            "/repos/\(owner)/\(repository)/contents/\(path)"
        components.queryItems = [
            URLQueryItem(
                name: "ref",
                value: branch
            )
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let data = try await request(url)
        let response = try JSONDecoder().decode(
            GitHubContentResponse.self,
            from: data
        )

        let base64 = response.content.replacingOccurrences(
            of: "\n",
            with: ""
        )

        guard
            let decoded = Data(base64Encoded: base64),
            let text = String(data: decoded, encoding: .utf8)
        else {
            throw URLError(.cannotDecodeContentData)
        }

        return text
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "TRAVIS-AI-Assistant",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)

        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private func select(paths: [String], task: String) -> [String] {
        let preferred = [
            "Travis_Multiplatform_Ai/Agent/Runtime/AgentRuntimeModels.swift",
            "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
            "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
            "Travis_Multiplatform_Ai/Agent/Runtime/TaskPlanner.swift",
            "Travis_Multiplatform_Ai/Agent/AgentCapability.swift",
            "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift",
            "Travis_Multiplatform_Ai/Agent/ApprovalGateService.swift",
            "Travis_Multiplatform_Ai/Agent/SelfImprovementCapability.swift",
            "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
            "Travis_Multiplatform_Ai/Services/AIService.swift",
            "Travis_Multiplatform_Ai/Services/PersistenceService.swift",
            "Travis_Multiplatform_Ai/Features/Chat/ChatView.swift"
        ]

        var result = preferred.filter(paths.contains)

        let terms = task
            .lowercased()
            .components(
                separatedBy: CharacterSet.alphanumerics.inverted
            )
            .filter {
                $0.count >= 4
            }

        let ranked = paths
            .filter {
                !result.contains($0)
            }
            .map { path -> (String, Int) in
                let lower = path.lowercased()
                var score = 0

                if lower.contains("/runtime/") {
                    score += 8
                }

                if lower.contains("/agent/") {
                    score += 6
                }

                if lower.contains("/services/") {
                    score += 3
                }

                for term in terms where lower.contains(term) {
                    score += 5
                }

                return (path, score)
            }
            .filter {
                $0.1 > 0
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                ? lhs.0 < rhs.0
                : lhs.1 > rhs.1
            }

        for (path, _) in ranked where result.count < maxSelectedFiles {
            result.append(path)
        }

        return Array(result.prefix(maxSelectedFiles))
    }
}

private struct GitHubTreeResponse: Decodable {
    let tree: [GitHubTreeItem]
}

private struct GitHubTreeItem: Decodable {
    let path: String
    let type: String
}

private struct GitHubContentResponse: Decodable {
    let content: String
}
