import Foundation

enum RepositoryGroundingError: LocalizedError {
    case invalidStructuredResponse
    case invalidEvidenceReferences([String])
    case noLoadedSourceEvidence
    case rawPathReferenceForbidden([String])

    var errorDescription: String? {
        switch self {
        case .invalidStructuredResponse:
            return "Repository analysis returned invalid structured JSON."
        case .invalidEvidenceReferences(let references):
            return "Repository analysis referenced invalid evidence IDs: \(references.joined(separator: ", "))."
        case .noLoadedSourceEvidence:
            return "Repository analysis did not reference any loaded source evidence."
        case .rawPathReferenceForbidden(let paths):
            return "Repository analysis wrote source paths directly instead of using evidence IDs: \(paths.joined(separator: ", "))."
        }
    }
}

enum RepositoryTransportError: LocalizedError {
    case invalidResponse
    case httpError(status: Int, message: String, remaining: String?, reset: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub repository service returned an invalid HTTP response."
        case .httpError(let status, let message, let remaining, let reset):
            var details = "GitHub API HTTP \(status)"
            if !message.isEmpty { details += ": \(message)" }
            if let remaining { details += " | rate-limit remaining: \(remaining)" }
            if let reset { details += " | reset: \(reset)" }
            return details
        }
    }
}

@MainActor
final class RepositoryContextCapability: AgentCapability {
    let id = "repository_context"
    let name = "Repository Context"
    let capabilityDescription = "Read-only ανάλυση του πραγματικού GitHub repository και source code του TRAVIS."

    let keywords = [
        "repository", "repo", "codebase", "source code", "architecture",
        "runtime", "κώδικ", "αρχιτεκτον", "project travis", "travis project"
    ]

    private(set) var status: AgentCapabilityStatus = .idle

    private let aiService: AIService
    private let repositoryService: GitHubRepositoryContextService
    private let maxAnalysisAttempts = 3

    init(
        aiService: AIService = .shared,
        repositoryService: GitHubRepositoryContextService = GitHubRepositoryContextService()
    ) {
        self.aiService = aiService
        self.repositoryService = repositoryService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let snapshot = try await repositoryService.context(for: command)
        let catalog = RepositoryEvidenceCatalog(paths: snapshot.loadedSourcePaths)

        var correctiveFeedback: String?
        var lastError: Error?

        for attempt in 1...maxAnalysisAttempts {
            let prompt = buildPrompt(
                command: command,
                snapshot: snapshot,
                evidenceCatalog: catalog,
                correctiveFeedback: correctiveFeedback
            )

            do {
                let raw = try await aiService.generateText(prompt: prompt, maxTokens: 6000)
                let response = try decodeStructuredResponse(raw)
                try validateStructuredResponse(response, raw: raw, catalog: catalog)
                return .reply(render(response, catalog: catalog))
            } catch {
                lastError = error
                guard attempt < maxAnalysisAttempts else { throw error }
                correctiveFeedback = correctiveFeedbackForRetry(error: error, catalog: catalog)
            }
        }

        throw lastError ?? RepositoryGroundingError.invalidStructuredResponse
    }

    func resolve(_ action: ProposedAction) {}

    private func buildPrompt(
        command: String,
        snapshot: RepositoryContextSnapshot,
        evidenceCatalog: RepositoryEvidenceCatalog,
        correctiveFeedback: String?
    ) -> String {
        let evidenceManifest = evidenceCatalog.entries
            .map(\.id)
            .joined(separator: ", ")

        let coverageManifest = snapshot.evidenceCoverage
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")

        let retryBlock: String
        if let correctiveFeedback {
            retryBlock = """

            PREVIOUS ATTEMPT WAS REJECTED BY DETERMINISTIC VALIDATION:
            \(correctiveFeedback)
            Correct the response without repeating the rejected behavior.
            """
        } else {
            retryBlock = ""
        }

        return """
        You are the repository-analysis component of TRAVIS.

        TASK:
        \(command)

        EVIDENCE PROFILE:
        \(snapshot.profile.rawValue)

        EVIDENCE COVERAGE:
        \(coverageManifest)

        STRICT GROUNDING CONTRACT:
        - Analyze only the evidence supplied below.
        - Exact filenames and repository paths are intentionally hidden from you.
        - Evidence files are identified only by E1, E2, E3, etc.
        - NEVER write a filename, extension, directory path, or repository path inside any JSON text field.
        - NEVER guess what an evidence ID's filename might be.
        - NEVER invent evidence IDs.
        - evidenceRefs may contain only IDs from ALLOWED EVIDENCE IDS.
        - Every observation and every finding must cite at least one evidenceRef.
        - Positive claims must identify a concrete symbol, control-flow branch, state transition, API call, or data-flow behavior in evidenceDetail.
        - Absence claims such as "no timeout", "no persistence", "no guard", or "no telemetry" are allowed only when the relevant EVIDENCE COVERAGE says FULL for the inspected concern.
        - If the evidence scope is incomplete, say so in limitations instead of claiming absence.
        - Do not invent files, types, APIs, persistence, workers, tests, configuration, or runtime behavior.
        - Recommendations are proposals only; never present them as existing implementation.
        - Return ONLY syntactically valid JSON.

        ALLOWED EVIDENCE IDS:
        \(evidenceManifest)

        LOADED SOURCE EVIDENCE:
        \(evidenceCatalog.annotatedSources(snapshot.sources))

        REQUIRED JSON SCHEMA:
        {
          "summary": "concise grounded result",
          "observations": [
            {
              "statement": "verified observation without path text",
              "evidenceDetail": "specific symbol/control-flow/state/data-flow evidence",
              "evidenceRefs": ["E1"]
            }
          ],
          "findings": [
            {
              "title": "finding title without path text",
              "severity": "critical|high|medium|low|null",
              "explanation": "what the evidence demonstrates",
              "evidenceDetail": "specific symbol/control-flow/state/data-flow evidence",
              "impact": "technical impact or null",
              "recommendation": "specific remediation or null",
              "evidenceRefs": ["E1", "E2"]
            }
          ],
          "limitations": ["anything not verifiable from this evidence profile"]
        }

        Rules:
        - inspection/mapping steps may return observations with zero findings
        - combined observations + findings must contain at least one evidence reference
        - evidenceDetail must be concrete, not generic
        - severity must be critical, high, medium, low, or null
        \(retryBlock)
        """
    }

    private func decodeStructuredResponse(_ raw: String) throws -> RepositoryStructuredResponse {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).removingRepositoryJSONFence()
        guard let data = cleaned.data(using: .utf8) else {
            throw RepositoryGroundingError.invalidStructuredResponse
        }
        do {
            return try JSONDecoder().decode(RepositoryStructuredResponse.self, from: data)
        } catch {
            throw RepositoryGroundingError.invalidStructuredResponse
        }
    }

    private func validateStructuredResponse(
        _ response: RepositoryStructuredResponse,
        raw: String,
        catalog: RepositoryEvidenceCatalog
    ) throws {
        // Free-text path-like tokens are sanitized deterministically during
        // render(). Grounding authority comes exclusively from evidenceRefs.
        let refs = response.observations.flatMap(\.evidenceRefs) + response.findings.flatMap(\.evidenceRefs)
        let invalid = Array(Set(refs.filter { !catalog.allowedIDs.contains($0) })).sorted()
        guard invalid.isEmpty else { throw RepositoryGroundingError.invalidEvidenceReferences(invalid) }
        guard !refs.isEmpty else { throw RepositoryGroundingError.noLoadedSourceEvidence }

        for observation in response.observations {
            guard !observation.evidenceRefs.isEmpty,
                  !observation.evidenceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw RepositoryGroundingError.noLoadedSourceEvidence }
        }

        for finding in response.findings {
            guard !finding.evidenceRefs.isEmpty,
                  !finding.evidenceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw RepositoryGroundingError.noLoadedSourceEvidence }
            if let severity = finding.severity {
                guard RepositoryFindingSeverity(rawValue: severity.lowercased()) != nil else {
                    throw RepositoryGroundingError.invalidStructuredResponse
                }
            }
        }
    }

    private func correctiveFeedbackForRetry(error: Error, catalog: RepositoryEvidenceCatalog) -> String {
        let allowed = catalog.entries.map(\.id).joined(separator: ", ")
        if let groundingError = error as? RepositoryGroundingError {
            switch groundingError {
            case .rawPathReferenceForbidden:
                return "Do not emit path-like text. Cite only evidence IDs: \(allowed)."
            case .invalidEvidenceReferences(let references):
                return "Invalid evidence IDs: \(references.joined(separator: ", ")). Allowed: \(allowed)."
            case .noLoadedSourceEvidence:
                return "Every observation/finding needs evidenceRefs and a concrete evidenceDetail. Allowed IDs: \(allowed)."
            case .invalidStructuredResponse:
                return "Return only valid JSON matching the required schema and cite only: \(allowed)."
            }
        }
        return "Previous response failed validation. Use only evidence IDs: \(allowed)."
    }

    private func render(_ response: RepositoryStructuredResponse, catalog: RepositoryEvidenceCatalog) -> String {
        var sections: [String] = [RepositoryFreeTextSanitizer.sanitize(response.summary)]

        if !response.observations.isEmpty {
            var lines = ["VERIFIED OBSERVATIONS"]
            for (index, observation) in response.observations.enumerated() {
                let evidence = catalog.paths(for: observation.evidenceRefs).map { "`\($0)`" }.joined(separator: ", ")
                let statement = RepositoryFreeTextSanitizer.sanitize(observation.statement)
                let detail = RepositoryFreeTextSanitizer.sanitize(observation.evidenceDetail)
                lines.append("\(index + 1). \(statement)\n   Source evidence: \(detail)\n   Evidence: \(evidence)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !response.findings.isEmpty {
            var lines = ["FINDINGS"]
            for (index, finding) in response.findings.enumerated() {
                let severity = finding.severity?.uppercased() ?? "UNRANKED"
                let evidence = catalog.paths(for: finding.evidenceRefs).map { "`\($0)`" }.joined(separator: ", ")
                let title = RepositoryFreeTextSanitizer.sanitize(finding.title)
                let explanation = RepositoryFreeTextSanitizer.sanitize(finding.explanation)
                let detail = RepositoryFreeTextSanitizer.sanitize(finding.evidenceDetail)
                var block = "\(index + 1). [\(severity)] \(title)\n   \(explanation)\n   Source evidence: \(detail)"
                if let impact = finding.impact, !impact.isEmpty {
                    block += "\n   Impact: \(RepositoryFreeTextSanitizer.sanitize(impact))"
                }
                if let recommendation = finding.recommendation, !recommendation.isEmpty {
                    block += "\n   Recommendation: \(RepositoryFreeTextSanitizer.sanitize(recommendation))"
                }
                block += "\n   Evidence: \(evidence)"
                lines.append(block)
            }
            sections.append(lines.joined(separator: "\n\n"))
        }

        if !response.limitations.isEmpty {
            sections.append(
                "LIMITATIONS\n" + response.limitations
                    .map { "- \(RepositoryFreeTextSanitizer.sanitize($0))" }
                    .joined(separator: "\n")
            )
        }

        return sections.joined(separator: "\n\n")
    }
}

private struct RepositoryStructuredResponse: Decodable {
    let summary: String
    let observations: [RepositoryObservation]
    let findings: [RepositoryFinding]
    let limitations: [String]
}

private struct RepositoryObservation: Decodable {
    let statement: String
    let evidenceDetail: String
    let evidenceRefs: [String]
}

private struct RepositoryFinding: Decodable {
    let title: String
    let severity: String?
    let explanation: String
    let evidenceDetail: String
    let impact: String?
    let recommendation: String?
    let evidenceRefs: [String]
}

private enum RepositoryFindingSeverity: String {
    case critical, high, medium, low
}

private struct RepositoryEvidenceCatalog {
    struct Entry {
        let id: String
        let path: String
    }

    let entries: [Entry]
    let allowedIDs: Set<String>

    init(paths: [String]) {
        entries = paths.enumerated().map { Entry(id: "E\($0.offset + 1)", path: $0.element) }
        allowedIDs = Set(entries.map(\.id))
    }

    func paths(for references: [String]) -> [String] {
        let requested = Set(references)
        return entries.filter { requested.contains($0.id) }.map(\.path)
    }

    func annotatedSources(_ sources: String) -> String {
        var value = sources
        for entry in entries {
            value = value.replacingOccurrences(
                of: "===== FILE: \(entry.path) =====",
                with: "===== EVIDENCE \(entry.id) ====="
            )
        }
        return value
    }
}

enum RepositoryEvidenceProfile: String {
    case bootstrap
    case runtime
    case persistence
    case capabilities
    case security
    case resilience
    case concurrency
    case observability
    case selfImprovement
    case general
}

struct RepositoryContextSnapshot {
    let repository: String
    let branch: String
    let profile: RepositoryEvidenceProfile
    let tree: String
    let sources: String
    let loadedSourcePaths: [String]
    let evidenceCoverage: [String: String]
}

final class GitHubRepositoryContextService {
    private let owner: String
    private let repository: String
    private let branch: String
    private let session: URLSession

    private let maxSelectedFiles = 10
    private let maxCharactersPerFile = 40_000
    private let maxTotalSourceCharacters = 220_000
    private let maxRequestAttempts = 3

    private var repositoryPathsCache: [String]?
    private var fileCache: [String: String] = [:]

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
        session = URLSession(configuration: configuration)
    }

    func context(for task: String) async throws -> RepositoryContextSnapshot {
        let repositoryPaths = try await fetchRepositoryPaths()
        let swiftPaths = repositoryPaths.filter { $0.hasSuffix(".swift") }
        let profile = profile(for: task)
        let selected = select(paths: swiftPaths, task: task, profile: profile)

        var chunks: [String] = []
        var loaded: [String] = []
        var totalCharacters = 0
        var coverage: [String: String] = [:]

        for path in selected {
            guard totalCharacters < maxTotalSourceCharacters else { break }

            let text: String
            do {
                text = try await fetchFile(path: path)
            } catch let error as RepositoryTransportError {
                throw error
            } catch {
                continue
            }

            let remaining = maxTotalSourceCharacters - totalCharacters
            let allowed = min(maxCharactersPerFile, remaining)
            let clipped = String(text.prefix(allowed))
            let full = clipped.count == text.count
            coverage["E\(loaded.count + 1)"] = full ? "FULL" : "TRUNCATED"

            let notice = full ? "" : "\n[FILE TRUNCATED BY REPOSITORY CONTEXT BUDGET]"
            chunks.append("===== FILE: \(path) =====\n\(clipped)\(notice)")
            loaded.append(path)
            totalCharacters += clipped.count
        }

        guard !chunks.isEmpty else { throw URLError(.cannotDecodeContentData) }

        let tree = repositoryPaths.sorted().prefix(400).joined(separator: "\n")

        return RepositoryContextSnapshot(
            repository: "\(owner)/\(repository)",
            branch: branch,
            profile: profile,
            tree: tree,
            sources: chunks.joined(separator: "\n\n"),
            loadedSourcePaths: loaded,
            evidenceCoverage: coverage
        )
    }

    private func profile(for task: String) -> RepositoryEvidenceProfile {
        let value = task.lowercased()

        if value.contains("entry point") || value.contains("bootstrap") || value.contains("top-level") || value.contains("map repository") || value.contains("χαρτογράφ") {
            return .bootstrap
        }
        if value.contains("persist") || value.contains("state management") || value.contains("memory") || value.contains("checkpoint") {
            return .persistence
        }
        if value.contains("capability") || value.contains("tool") || value.contains("plugin") || value.contains("routing") {
            return .capabilities
        }
        if value.contains("security") || value.contains("auth") || value.contains("secret") || value.contains("permission") || value.contains("approval") {
            return .security
        }
        if value.contains("error") || value.contains("retry") || value.contains("resilien") || value.contains("recovery") || value.contains("timeout") {
            return .resilience
        }
        if value.contains("concurr") || value.contains("race") || value.contains("locking") || value.contains("async") {
            return .concurrency
        }
        if value.contains("observ") || value.contains("logging") || value.contains("audit") || value.contains("telemetry") {
            return .observability
        }
        if value.contains("self-improvement") || value.contains("self modification") || value.contains("self-modification") {
            return .selfImprovement
        }
        if value.contains("runtime") || value.contains("executor") || value.contains("planner") || value.contains("autonomous") {
            return .runtime
        }
        return .general
    }

    private func select(paths: [String], task: String, profile: RepositoryEvidenceProfile) -> [String] {
        let bundles: [RepositoryEvidenceProfile: [String]] = [
            .bootstrap: [
                "Travis_Multiplatform_Ai/Travis_Multiplatform_Ai/Travis_Multiplatform_AiApp.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
                "Travis_Multiplatform_Ai/App/TRAVISRootView.swift",
                "Travis_Multiplatform_Ai/platform/Macos/MacAppShell.swift",
                "Travis_Multiplatform_Ai/platform/Ios/iOSAppShell.swift",
                "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift",
                "Travis_Multiplatform_Ai/Agent/AgentCapability.swift",
                "Travis_Multiplatform_Ai/Services/AIService.swift",
                "Travis_Multiplatform_Ai/Services/PersistenceService.swift",
                "Travis_Multiplatform_Ai/Services/KeychainService.swift"
            ],
            .runtime: [
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentRuntimeModels.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/TaskPlanner.swift",
                "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift",
                "Travis_Multiplatform_Ai/Agent/AgentCapability.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift"
            ],
            .persistence: [
                "Travis_Multiplatform_Ai/Services/PersistenceService.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentRuntimeModels.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
                "Travis_Multiplatform_Ai/Models/PersistedChatMessage.swift",
                "Travis_Multiplatform_Ai/Models/PersistedProposedAction.swift",
                "Travis_Multiplatform_Ai/Models/PersistedFile.swift"
            ],
            .capabilities: [
                "Travis_Multiplatform_Ai/Agent/AgentCapability.swift",
                "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift",
                "Travis_Multiplatform_Ai/Agent/TextTaskCapability.swift",
                "Travis_Multiplatform_Ai/Agent/RepositoryContextCapability.swift",
                "Travis_Multiplatform_Ai/Agent/SelfImprovementCapability.swift",
                "Travis_Multiplatform_Ai/Agent/CryptoTradingCapability.swift",
                "Travis_Multiplatform_Ai/Agent/ApprovalGateService.swift"
            ],
            .security: [
                "Travis_Multiplatform_Ai/Agent/ApprovalGateService.swift",
                "Travis_Multiplatform_Ai/Services/PermissionService.swift",
                "Travis_Multiplatform_Ai/Services/KeychainService.swift",
                "Travis_Multiplatform_Ai/Models/TravisPermission.swift",
                "Travis_Multiplatform_Ai/Models/StandingPermission.swift",
                "Travis_Multiplatform_Ai/Agent/SelfImprovementCapability.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift"
            ],
            .resilience: [
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentRuntimeModels.swift",
                "Travis_Multiplatform_Ai/Services/AIService.swift",
                "Travis_Multiplatform_Ai/Agent/RepositoryContextCapability.swift"
            ],
            .concurrency: [
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
                "Travis_Multiplatform_Ai/Services/AIService.swift",
                "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift"
            ],
            .observability: [
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentRuntimeModels.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
                "Travis_Multiplatform_Ai/Services/PersistenceService.swift"
            ],
            .selfImprovement: [
                "Travis_Multiplatform_Ai/Agent/SelfImprovementCapability.swift",
                "Travis_Multiplatform_Ai/Agent/ApprovalGateService.swift",
                "Travis_Multiplatform_Ai/Agent/AgentCapability.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift"
            ],
            .general: [
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskRuntime.swift",
                "Travis_Multiplatform_Ai/Agent/Runtime/TaskPlanner.swift",
                "Travis_Multiplatform_Ai/Agent/AgentOrchestrator.swift",
                "Travis_Multiplatform_Ai/App/TRAVISAppState.swift",
                "Travis_Multiplatform_Ai/Services/AIService.swift"
            ]
        ]

        var result = (bundles[profile] ?? []).filter { paths.contains($0) }
        let terms = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }

        var ranked: [(path: String, score: Int)] = []
        for path in paths where !result.contains(path) {
            let lower = path.lowercased()
            var score = 0
            for term in terms where lower.contains(term) { score += 6 }
            if lower.contains("/runtime/") { score += 3 }
            if lower.contains("/agent/") { score += 2 }
            if lower.contains("/services/") { score += 1 }
            if score > 0 { ranked.append((path, score)) }
        }

        ranked.sort {
            if $0.score == $1.score { return $0.path < $1.path }
            return $0.score > $1.score
        }

        for item in ranked where result.count < maxSelectedFiles {
            result.append(item.path)
        }

        return Array(result.prefix(maxSelectedFiles))
    }

    private func fetchRepositoryPaths() async throws -> [String] {
        if let cached = repositoryPathsCache { return cached }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(encodedBranch)?recursive=1") else {
            throw URLError(.badURL)
        }

        let data = try await request(url)
        let tree = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)
        let paths = tree.tree.compactMap { $0.type == "blob" ? $0.path : nil }
        repositoryPathsCache = paths
        return paths
    }

    private func fetchFile(path: String) async throws -> String {
        if let cached = fileCache[path] { return cached }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components.url else { throw URLError(.badURL) }

        let data = try await request(url)
        let response = try JSONDecoder().decode(GitHubContentResponse.self, from: data)
        let base64 = response.content.replacingOccurrences(of: "\n", with: "")

        guard let decoded = Data(base64Encoded: base64),
              let text = String(data: decoded, encoding: .utf8)
        else { throw URLError(.cannotDecodeContentData) }

        fileCache[path] = text
        return text
    }

    private func request(_ url: URL) async throws -> Data {
        var lastError: Error?

        for attempt in 1...maxRequestAttempts {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TRAVIS-AI-Assistant", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RepositoryTransportError.invalidResponse
                }

                if (200..<300).contains(http.statusCode) { return data }

                let error = RepositoryTransportError.httpError(
                    status: http.statusCode,
                    message: Self.githubMessage(from: data),
                    remaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                    reset: http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                )

                if Self.isRetryable(status: http.statusCode), attempt < maxRequestAttempts {
                    lastError = error
                    try? await Task.sleep(for: .seconds(UInt64(attempt * attempt)))
                    continue
                }
                throw error
            } catch {
                lastError = error
                if error is RepositoryTransportError { throw error }
                if attempt < maxRequestAttempts {
                    try? await Task.sleep(for: .seconds(UInt64(attempt * attempt)))
                    continue
                }
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 429 || status == 502 || status == 503 || status == 504
    }

    private static func githubMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "" }
        return message
    }
}

private enum SourcePathExtractor {
    private static let pattern = #"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:swift|py|js|jsx|ts|tsx|json|ya?ml|toml|md|sh|pbxproj|xcconfig)"#

    static func extract(from text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}

private enum RepositoryFreeTextSanitizer {
    private static let pattern = #"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:swift|py|js|jsx|ts|tsx|json|ya?ml|toml|md|sh|pbxproj|xcconfig)"#

    static func sanitize(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "[source reference omitted]"
        )
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

private extension String {
    func removingRepositoryJSONFence() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json") {
            value.removeFirst("```json".count)
        } else if value.hasPrefix("```") {
            value.removeFirst(3)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("```") { value.removeLast(3) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
