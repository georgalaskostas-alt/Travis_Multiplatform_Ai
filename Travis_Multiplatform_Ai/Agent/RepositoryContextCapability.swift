import Foundation

enum RepositoryGroundingError: LocalizedError {
    case unknownSourcePaths([String])
    case noLoadedSourceEvidence

    var errorDescription: String? {
        switch self {
        case .unknownSourcePaths(let paths):
            return "Repository analysis referenced unknown source paths: \(paths.joined(separator: ", "))."
        case .noLoadedSourceEvidence:
            return "Repository analysis did not cite any source file that was actually loaded as evidence."
        }
    }
}

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

        let loadedEvidenceManifest = snapshot.loadedSourcePaths
            .map { "- \($0)" }
            .joined(separator: "\n")

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
        - Do not claim you inspected files that are not included in LOADED EVIDENCE FILES.
        - Do not invent filenames, directories, types, APIs, persistence, workers, tests, behavior, or capabilities.
        - Clearly separate verified observations from recommendations.
        - This capability is read-only. Do not claim code was modified.
        - You do not have access to local uncommitted changes.
        - For every important finding, cite at least one concrete path from LOADED EVIDENCE FILES.
        - Prefer evidence-backed findings over generic autonomous-agent advice.
        - Never provide illustrative code as if it came from the repository.
        - If evidence is insufficient, explicitly say that instead of filling the gap.

        LOADED EVIDENCE FILES:
        \(loadedEvidenceManifest)

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

        try validateGrounding(
            result,
            snapshot: snapshot
        )

        return .reply(result)
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability. It never produces state-changing proposals.
    }

    private func validateGrounding(
        _ result: String,
        snapshot: RepositoryContextSnapshot
    ) throws {
        let mentionedPaths = SourcePathExtractor.extract(from: result)

        var unknownPaths: [String] = []
        var hasLoadedEvidence = false

        for candidate in mentionedPaths {
            let normalized = candidate.trimmingCharacters(
                in: CharacterSet(charactersIn: "`'\"()[]{}:,;")
            )

            if path(
                normalized,
                resolvesWithin: snapshot.loadedSourcePaths
            ) {
                hasLoadedEvidence = true
            }

            if !path(
                normalized,
                resolvesWithin: snapshot.repositoryPaths
            ) {
                unknownPaths.append(normalized)
            }
        }

        let uniqueUnknown = Array(Set(unknownPaths)).sorted()

        guard uniqueUnknown.isEmpty else {
            throw RepositoryGroundingError.unknownSourcePaths(uniqueUnknown)
        }

        guard hasLoadedEvidence else {
            throw RepositoryGroundingError.noLoadedSourceEvidence
        }
    }

    private func path(
        _ candidate: String,
        resolvesWithin paths: [String]
    ) -> Bool {
        if paths.contains(candidate) {
            return true
        }

        let suffix = "/\(candidate)"
        return paths.contains { existing in
            existing.hasSuffix(suffix)
        }
    }
}

struct RepositoryContextSnapshot {
    let repository: String
    let branch: String
    let tree: String
    let sources: String
    let repositoryPaths: [String]
    let loadedSourcePaths: [String]
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
        let repositoryPaths = try await fetchRepositoryPaths()

        let swiftPaths = repositoryPaths.filter { path in
            path.hasSuffix(".swift")
        }

        let selected = select(
            paths: swiftPaths,
            task: task
        )

        var chunks: [String] = []
        var loadedSourcePaths: [String] = []
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

            loadedSourcePaths.append(path)
            totalCharacters += clipped.count
        }

        guard !chunks.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        let tree = repositoryPaths
            .sorted()
            .prefix(300)
            .joined(separator: "\n")

        return RepositoryContextSnapshot(
            repository: "\(owner)/\(repository)",
            branch: branch,
            tree: tree,
            sources: chunks.joined(separator: "\n\n"),
            repositoryPaths: repositoryPaths,
            loadedSourcePaths: loadedSourcePaths
        )
    }

    private func fetchRepositoryPaths() async throws -> [String] {
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

        return tree.tree.compactMap { item in
            guard item.type == "blob" else {
                return nil
            }

            return item.path
        }
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

        var result: [String] = []

        for preferredPath in preferred {
            if paths.contains(preferredPath) {
                result.append(preferredPath)
            }
        }

        let terms = task
            .lowercased()
            .components(
                separatedBy: CharacterSet.alphanumerics.inverted
            )
            .filter {
                $0.count >= 4
            }

        var ranked: [(path: String, score: Int)] = []

        for path in paths {
            guard !result.contains(path) else {
                continue
            }

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

            for term in terms {
                if lower.contains(term) {
                    score += 5
                }
            }

            if score > 0 {
                ranked.append((path: path, score: score))
            }
        }

        ranked.sort { left, right in
            if left.score == right.score {
                return left.path < right.path
            }

            return left.score > right.score
        }

        for item in ranked {
            guard result.count < maxSelectedFiles else {
                break
            }

            result.append(item.path)
        }

        return Array(result.prefix(maxSelectedFiles))
    }
}

private enum SourcePathExtractor {
    private static let pattern =
        #"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:swift|py|js|jsx|ts|tsx|json|ya?ml|toml|md|sh|pbxproj|xcconfig)"#

    static func extract(from text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else {
            return []
        }

        let fullRange = NSRange(
            text.startIndex..<text.endIndex,
            in: text
        )

        let matches = expression.matches(
            in: text,
            options: [],
            range: fullRange
        )

        var paths: [String] = []

        for match in matches {
            guard let range = Range(match.range, in: text) else {
                continue
            }

            paths.append(String(text[range]))
        }

        return paths
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
