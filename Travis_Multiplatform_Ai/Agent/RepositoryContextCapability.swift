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
            if !message.isEmpty {
                details += ": \(message)"
            }
            if let remaining {
                details += " | rate-limit remaining: \(remaining)"
            }
            if let reset {
                details += " | reset: \(reset)"
            }
            return details
        }
    }
}

/// Read-only, repository-grounded analysis capability.
///
/// Grounding v2 deliberately does NOT let the model cite filenames directly.
/// Loaded source files are exposed as opaque evidence IDs (E1, E2, ...).
/// The model returns structured JSON containing only those IDs, and Swift maps
/// them back to exact repository paths after deterministic validation.
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
    private let maxAnalysisAttempts = 3

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
        let evidenceCatalog = RepositoryEvidenceCatalog(paths: snapshot.loadedSourcePaths)

        var correctiveFeedback: String?
        var lastError: Error?

        for attempt in 1...maxAnalysisAttempts {
            let prompt = buildPrompt(
                command: command,
                snapshot: snapshot,
                evidenceCatalog: evidenceCatalog,
                correctiveFeedback: correctiveFeedback
            )

            do {
                let raw = try await aiService.generateText(
                    prompt: prompt,
                    maxTokens: 5000
                )

                let response = try decodeStructuredResponse(raw)
                try validateStructuredResponse(
                    response,
                    raw: raw,
                    catalog: evidenceCatalog
                )

                let rendered = render(
                    response,
                    catalog: evidenceCatalog
                )

                return .reply(rendered)
            } catch {
                lastError = error

                guard attempt < maxAnalysisAttempts else {
                    throw error
                }

                correctiveFeedback = correctiveFeedbackForRetry(
                    error: error,
                    catalog: evidenceCatalog
                )
            }
        }

        throw lastError ?? RepositoryGroundingError.invalidStructuredResponse
    }

    func resolve(_ action: ProposedAction) {
        // Read-only capability. It never produces state-changing proposals.
    }

    // MARK: - Structured grounding

    private func buildPrompt(
        command: String,
        snapshot: RepositoryContextSnapshot,
        evidenceCatalog: RepositoryEvidenceCatalog,
        correctiveFeedback: String?
    ) -> String {
        let evidenceManifest = evidenceCatalog.entries
            .map { "\($0.id) = \($0.path)" }
            .joined(separator: "\n")

        let retryBlock: String
        if let correctiveFeedback {
            retryBlock = """

            PREVIOUS ATTEMPT WAS REJECTED BY DETERMINISTIC VALIDATION:
            \(correctiveFeedback)

            Correct the response. Do not repeat the rejected behavior.
            """
        } else {
            retryBlock = ""
        }

        return """
        You are the repository-analysis component of TRAVIS.

        TASK:
        \(command)

        REPOSITORY:
        \(snapshot.repository)

        BRANCH:
        \(snapshot.branch)

        STRICT GROUNDING CONTRACT:
        - Analyze only the evidence supplied below.
        - Evidence files are identified ONLY by opaque IDs E1, E2, E3, etc.
        - NEVER write a filename, extension, directory path, or repository path inside any JSON text field.
        - NEVER invent a new evidence ID.
        - evidenceRefs may contain ONLY IDs from ALLOWED EVIDENCE IDS.
        - Every substantive observation must have at least one evidenceRef.
        - Every finding must have at least one evidenceRef.
        - Every finding must describe concrete source-level evidence in evidenceDetail: a real type, method, state transition, condition, call path, retry rule, data mutation, or control-flow behavior visible in the supplied source.
        - Prefer positive evidence (what the code demonstrably does) over absence claims.
        - A claim that a guard, timeout, recovery path, validation, telemetry, lock, or other mechanism is ABSENT is allowed only when the relevant evidence unit is complete. If an evidence block contains an EVIDENCE TRUNCATED notice, do NOT use that evidence to prove absence. State the uncertainty in limitations instead.
        - If evidence is insufficient, state that in limitations instead of guessing.
        - Do not invent types, APIs, persistence, workers, tests, behavior, capabilities, entry points, or configuration.
        - Recommendations may describe proposed architecture, but must never be presented as existing code.
        - Return ONLY syntactically valid JSON. No markdown fences and no commentary.

        ALLOWED EVIDENCE IDS:
        \(evidenceManifest)

        REPOSITORY TREE FOR ORIENTATION ONLY:
        \(snapshot.tree)

        LOADED SOURCE EVIDENCE:
        \(evidenceCatalog.annotatedSources(snapshot.sources))

        REQUIRED JSON SCHEMA:
        {
          "summary": "concise evidence-grounded result",
          "observations": [
            {
              "statement": "verified observation without any filename/path text",
              "evidenceRefs": ["E1"]
            }
          ],
          "findings": [
            {
              "title": "finding title without any filename/path text",
              "severity": "critical|high|medium|low|null",
              "explanation": "what the evidence demonstrates",
              "evidenceDetail": "specific symbol/control-flow/state behavior observed in the loaded source; do not include a filename/path",
              "impact": "technical impact or null",
              "recommendation": "specific remediation or null",
              "evidenceRefs": ["E1", "E2"]
            }
          ],
          "limitations": [
            "anything that could not be verified from supplied evidence"
          ]
        }

        Rules:
        - observations may be empty only if findings is non-empty
        - findings may be empty for inspection/mapping steps
        - the combined observations + findings must contain at least one evidence reference
        - severity must be one of critical, high, medium, low, or null
        - evidenceDetail must be non-empty for every finding
        - do not infer repository-wide absence from a partial or truncated source excerpt
        - do not include invented source excerpts; describe the exact observed implementation/control flow instead
        \(retryBlock)
        """
    }

    private func decodeStructuredResponse(
        _ raw: String
    ) throws -> RepositoryStructuredResponse {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingRepositoryJSONFence()

        guard let data = cleaned.data(using: .utf8) else {
            throw RepositoryGroundingError.invalidStructuredResponse
        }

        do {
            return try JSONDecoder().decode(
                RepositoryStructuredResponse.self,
                from: data
            )
        } catch {
            throw RepositoryGroundingError.invalidStructuredResponse
        }
    }

    private func validateStructuredResponse(
        _ response: RepositoryStructuredResponse,
        raw: String,
        catalog: RepositoryEvidenceCatalog
    ) throws {
        // The model is forbidden from emitting path-like strings at all.
        // Exact paths are injected only after validation by Swift.
        let directlyWrittenPaths = SourcePathExtractor.extract(from: raw)
        if !directlyWrittenPaths.isEmpty {
            throw RepositoryGroundingError.rawPathReferenceForbidden(
                Array(Set(directlyWrittenPaths)).sorted()
            )
        }

        let allReferences = response.observations.flatMap(\.evidenceRefs)
            + response.findings.flatMap(\.evidenceRefs)

        let invalidReferences = Array(
            Set(allReferences.filter { !catalog.allowedIDs.contains($0) })
        ).sorted()

        guard invalidReferences.isEmpty else {
            throw RepositoryGroundingError.invalidEvidenceReferences(
                invalidReferences
            )
        }

        guard !allReferences.isEmpty else {
            throw RepositoryGroundingError.noLoadedSourceEvidence
        }

        for observation in response.observations {
            guard !observation.evidenceRefs.isEmpty else {
                throw RepositoryGroundingError.noLoadedSourceEvidence
            }
        }

        for finding in response.findings {
            guard !finding.evidenceRefs.isEmpty else {
                throw RepositoryGroundingError.noLoadedSourceEvidence
            }

            guard !finding.evidenceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepositoryGroundingError.invalidStructuredResponse
            }

            if let severity = finding.severity {
                guard RepositoryFindingSeverity(rawValue: severity.lowercased()) != nil else {
                    throw RepositoryGroundingError.invalidStructuredResponse
                }
            }
        }
    }

    private func correctiveFeedbackForRetry(
        error: Error,
        catalog: RepositoryEvidenceCatalog
    ) -> String {
        let allowed = catalog.entries
            .map(\.id)
            .joined(separator: ", ")

        if let groundingError = error as? RepositoryGroundingError {
            switch groundingError {
            case .rawPathReferenceForbidden(let paths):
                return "You wrote forbidden path-like strings: \(paths.joined(separator: ", ")). Do not write filenames or paths anywhere. Cite only evidence IDs: \(allowed)."
            case .invalidEvidenceReferences(let references):
                return "Invalid evidence IDs were used: \(references.joined(separator: ", ")). Allowed IDs are only: \(allowed)."
            case .noLoadedSourceEvidence:
                return "The response lacked evidence references. Every substantive observation/finding must cite at least one of: \(allowed)."
            case .invalidStructuredResponse:
                return "The response was not valid JSON matching the required schema, or a finding lacked evidenceDetail. Return only the requested JSON object and use only evidence IDs: \(allowed)."
            }
        }

        return "The previous response failed validation: \(error.localizedDescription). Return valid JSON and cite only these evidence IDs: \(allowed)."
    }

    private func render(
        _ response: RepositoryStructuredResponse,
        catalog: RepositoryEvidenceCatalog
    ) -> String {
        var sections: [String] = []

        sections.append(response.summary)

        if !response.observations.isEmpty {
            var lines: [String] = ["VERIFIED OBSERVATIONS"]

            for (index, observation) in response.observations.enumerated() {
                let evidence = catalog.paths(for: observation.evidenceRefs)
                    .map { "`\($0)`" }
                    .joined(separator: ", ")

                lines.append(
                    "\(index + 1). \(observation.statement)\n   Evidence: \(evidence)"
                )
            }

            sections.append(lines.joined(separator: "\n"))
        }

        if !response.findings.isEmpty {
            var lines: [String] = ["FINDINGS"]

            for (index, finding) in response.findings.enumerated() {
                let severity = finding.severity?.uppercased() ?? "UNRANKED"
                let evidence = catalog.paths(for: finding.evidenceRefs)
                    .map { "`\($0)`" }
                    .joined(separator: ", ")

                var block = "\(index + 1). [\(severity)] \(finding.title)\n   \(finding.explanation)"
                block += "\n   Source evidence: \(finding.evidenceDetail)"

                if let impact = finding.impact, !impact.isEmpty {
                    block += "\n   Impact: \(impact)"
                }

                if let recommendation = finding.recommendation, !recommendation.isEmpty {
                    block += "\n   Recommendation: \(recommendation)"
                }

                block += "\n   Evidence: \(evidence)"
                lines.append(block)
            }

            sections.append(lines.joined(separator: "\n\n"))
        }

        if !response.limitations.isEmpty {
            let limitations = response.limitations
                .map { "- \($0)" }
                .joined(separator: "\n")

            sections.append("LIMITATIONS\n\(limitations)")
        }

        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Structured repository response

private struct RepositoryStructuredResponse: Decodable {
    let summary: String
    let observations: [RepositoryObservation]
    let findings: [RepositoryFinding]
    let limitations: [String]
}

private struct RepositoryObservation: Decodable {
    let statement: String
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
    case critical
    case high
    case medium
    case low
}

private struct RepositoryEvidenceCatalog {
    struct Entry {
        let id: String
        let path: String
    }

    let entries: [Entry]
    let allowedIDs: Set<String>

    init(paths: [String]) {
        self.entries = paths.enumerated().map { index, path in
            Entry(id: "E\(index + 1)", path: path)
        }
        self.allowedIDs = Set(entries.map(\.id))
    }

    func paths(for references: [String]) -> [String] {
        let requested = Set(references)
        return entries
            .filter { requested.contains($0.id) }
            .map(\.path)
    }

    /// Replaces exact source-path headers with evidence IDs before the text is
    /// sent to the model. The model can inspect content but is instructed to
    /// cite only the opaque IDs in its response.
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

struct RepositoryContextSnapshot {
    let repository: String
    let branch: String
    let tree: String
    let sources: String
    let repositoryPaths: [String]
    let loadedSourcePaths: [String]
}

/// Read-only GitHub repository reader used by RepositoryContextCapability.
///
/// Runtime v1 intentionally caches the immutable branch snapshot and file
/// contents in memory. Without this cache, every autonomous analysis step
/// would refetch the same recursive tree plus the same source files and can
/// exhaust GitHub's unauthenticated API quota very quickly.
final class GitHubRepositoryContextService {
    private let owner: String
    private let repository: String
    private let branch: String
    private let session: URLSession

    // Evidence depth is intentionally biased toward fewer, more complete files.
    // The verifier can reason about real control flow far more reliably from six
    // mostly complete source units than from twelve shallow first-page excerpts.
    private let maxSelectedFiles = 7
    private let maxCharactersPerFile = 28_000
    private let maxTotalSourceCharacters = 150_000
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
        self.session = URLSession(configuration: configuration)
    }

    func context(for task: String) async throws -> RepositoryContextSnapshot {
        let repositoryPaths = try await fetchRepositoryPaths()
        let swiftPaths = repositoryPaths.filter { $0.hasSuffix(".swift") }
        let selected = select(paths: swiftPaths, task: task)

        var chunks: [String] = []
        var loadedSourcePaths: [String] = []
        var totalCharacters = 0

        for path in selected {
            guard totalCharacters < maxTotalSourceCharacters else {
                break
            }

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

            let truncationNotice = text.count > clipped.count
                ? "\n[EVIDENCE TRUNCATED: ABSENCE CLAIMS NOT PERMITTED FOR THIS FILE]"
                : "\n[EVIDENCE COMPLETE FOR THIS FILE]"

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
        if let cached = repositoryPathsCache {
            return cached
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )

        let encodedBranch = branch.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) ?? branch

        guard let url = URL(
            string: "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(encodedBranch)?recursive=1"
        ) else {
            throw URLError(.badURL)
        }

        let data = try await request(url)
        let tree = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)

        let paths = tree.tree.compactMap { item -> String? in
            guard item.type == "blob" else { return nil }
            return item.path
        }

        repositoryPathsCache = paths
        return paths
    }

    private func fetchFile(path: String) async throws -> String {
        if let cached = fileCache[path] {
            return cached
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let data = try await request(url)
        let response = try JSONDecoder().decode(GitHubContentResponse.self, from: data)

        let base64 = response.content.replacingOccurrences(of: "\n", with: "")

        guard
            let decoded = Data(base64Encoded: base64),
            let text = String(data: decoded, encoding: .utf8)
        else {
            throw URLError(.cannotDecodeContentData)
        }

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

                if (200..<300).contains(http.statusCode) {
                    return data
                }

                let message = Self.githubMessage(from: data)
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")

                let error = RepositoryTransportError.httpError(
                    status: http.statusCode,
                    message: message,
                    remaining: remaining,
                    reset: reset
                )

                if Self.isRetryable(status: http.statusCode), attempt < maxRequestAttempts {
                    lastError = error
                    let delay = UInt64(attempt * attempt)
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }

                throw error
            } catch {
                lastError = error

                if error is RepositoryTransportError {
                    throw error
                }

                if attempt < maxRequestAttempts {
                    let delay = UInt64(attempt * attempt)
                    try? await Task.sleep(for: .seconds(delay))
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
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String
        else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
        }

        return message
    }

    /// Select evidence for the CURRENT execution step, rather than blindly
    /// loading the same fixed bundle for every step.
    private func select(paths: [String], task: String) -> [String] {
        let taskLower = task.lowercased()
        let terms = taskLower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }

        let coreNames = [
            "agentruntimemodels.swift",
            "agenttaskruntime.swift",
            "agenttaskexecutor.swift",
            "taskplanner.swift",
            "agentcapability.swift",
            "agentorchestrator.swift",
            "approvalgateservice.swift",
            "selfimprovementcapability.swift",
            "travisappstate.swift",
            "aiservice.swift",
            "persistenceservice.swift",
            "keychainservice.swift"
        ]

        let semanticRules: [(markers: [String], pathTokens: [String], weight: Int)] = [
            (["concurrency", "race", "locking", "async", "parallel"],
             ["agenttaskexecutor", "agenttaskruntime", "agentorchestrator", "aiservice", "persistence"], 24),
            (["security", "auth", "secret", "permission", "approval", "trust"],
             ["approvalgate", "keychain", "selfimprovement", "executionservice", "cryptotrading", "agentorchestrator"], 24),
            (["planning", "planner", "scheduling", "replan", "retry", "error recovery"],
             ["taskplanner", "agenttaskexecutor", "agenttaskruntime", "agentruntimemodels"], 24),
            (["persistence", "state", "memory", "checkpoint", "recovery"],
             ["persistence", "agentruntimemodels", "agenttaskruntime", "travisappstate"], 24),
            (["observability", "logging", "telemetry", "audit", "trace"],
             ["agenttaskexecutor", "travisappstate", "aiservice", "approvalgate"], 22),
            (["capability", "plugin", "integration", "routing", "tool"],
             ["agentcapability", "agentorchestrator", "selfimprovement", "texttask", "cryptotrading", "repositorycontext"], 22),
            (["self-improvement", "self improvement", "self-modification", "self modification"],
             ["selfimprovement", "approvalgate", "agentorchestrator", "persistence"], 28),
            (["entry point", "top-level", "structure", "bootstrap"],
             ["appstate", "rootview", "app.swift", "agentorchestrator"], 18)
        ]

        var ranked: [(path: String, score: Int)] = []

        for path in paths {
            let lower = path.lowercased()
            var score = 0

            if lower.contains("/runtime/") { score += 8 }
            if lower.contains("/agent/") { score += 6 }
            if lower.contains("/services/") { score += 3 }

            if coreNames.contains(where: lower.hasSuffix) {
                score += 5
            }

            for term in terms where lower.contains(term) {
                score += 6
            }

            for rule in semanticRules {
                guard rule.markers.contains(where: taskLower.contains) else { continue }
                if rule.pathTokens.contains(where: lower.contains) {
                    score += rule.weight
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

        var result = ranked.prefix(maxSelectedFiles).map(\.path)

        // Always include at least one runtime/executor source unit when it exists.
        let executorPath = "Travis_Multiplatform_Ai/Agent/Runtime/AgentTaskExecutor.swift"
        if paths.contains(executorPath), !result.contains(executorPath), !result.isEmpty {
            result[result.count - 1] = executorPath
        }

        if result.isEmpty {
            result = Array(paths.sorted().prefix(maxSelectedFiles))
        }

        return result
    }
}

private enum SourcePathExtractor {
    private static let pattern =
        #"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:swift|py|js|jsx|ts|tsx|json|ya?ml|toml|md|sh|pbxproj|xcconfig)"#

    static func extract(from text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: fullRange)

        var paths: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
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

private extension String {
    func removingRepositoryJSONFence() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("```json") {
            value.removeFirst("```json".count)
        } else if value.hasPrefix("```") {
            value.removeFirst(3)
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasSuffix("```") {
            value.removeLast(3)
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
