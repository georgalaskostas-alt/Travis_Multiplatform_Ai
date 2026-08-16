import Foundation

@MainActor
final class CodingRepositoryCapability: AgentCapability {
    let id = "coding_repository"
    let name = "Coding Repository"
    let capabilityDescription = "Grounded coding agent για το TRAVIS repository: κάνει read-only inspection αυτόνομα και προτείνει exact file replacements που γίνονται commit μόνο μετά από approval."
    let keywords: [String] = [
        "γράψε κώδικα", "γραψε κωδικα", "άλλαξε κώδικα", "αλλαξε κωδικα",
        "fix code", "edit code", "apply change", "commit", "source file", "swift file"
    ]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .coding,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly, .codeMutation, .externalMutation],
                permissionKeys: ["github_write"],
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 180,
                maxAttempts: 2
            )
        )
    }

    var onExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let repositoryAnalysis: RepositoryContextCapability
    private let github: GitHubCodingService

    init(
        aiService: AIService = .shared,
        repositoryAnalysis: RepositoryContextCapability = RepositoryContextCapability(),
        github: GitHubCodingService = .shared
    ) {
        self.aiService = aiService
        self.repositoryAnalysis = repositoryAnalysis
        self.github = github
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let intent = try await classify(command, recentHistory: recentHistory)
        switch intent.mode {
        case "inspect":
            return try await repositoryAnalysis.handle(command: command, recentHistory: recentHistory)

        case "modify":
            guard let requestedPath = intent.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedPath.isEmpty else {
                // Without an exact path, first perform grounded repository analysis.
                // This avoids asking the model to invent a repository location.
                let analysis = try await repositoryAnalysis.handle(command: command, recentHistory: recentHistory)
                guard case .reply(let text) = analysis else { return analysis }
                return .reply("""
                CODING INSPECTION COMPLETE

                \(text)

                Για ασφαλή mutation χρειάζεται exact repository path στο επόμενο coding step. Ο planner μπορεί να χρησιμοποιήσει τα grounded paths παραπάνω και να εκτελέσει νέο coding_repository step με συγκεκριμένο target file.
                """)
            }

            return try await proposeReplacement(
                path: requestedPath,
                request: command,
                recentHistory: recentHistory
            )

        default:
            return try await repositoryAnalysis.handle(command: command, recentHistory: recentHistory)
        }
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let payload = action.payload,
              let data = payload.data(using: .utf8),
              let mutation = try? JSONDecoder().decode(MutationPayload.self, from: data) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onExecutionUpdate?("🔧 Εφαρμόζω approved GitHub mutation: \(mutation.path)")
            do {
                let commitSHA = try await self.github.replaceFile(
                    path: mutation.path,
                    expectedSHA: mutation.expectedSHA,
                    newContent: mutation.newContent,
                    commitMessage: mutation.commitMessage
                )
                self.onExecutionUpdate?("✅ GitHub commit ολοκληρώθηκε: \(String(commitSHA.prefix(10))) — \(mutation.path)")
            } catch {
                self.onExecutionUpdate?("❌ GitHub mutation απέτυχε χωρίς να παρακαμφθεί το SHA guard: \(error.localizedDescription)")
            }
        }
    }

    private struct IntentDecision: Decodable {
        let mode: String
        let path: String?
    }

    private struct MutationPayload: Codable {
        let path: String
        let expectedSHA: String
        let newContent: String
        let commitMessage: String
    }

    private func classify(_ command: String, recentHistory: [ChatMessage]) async throws -> IntentDecision {
        let prompt = """
        Classify a coding request for the TRAVIS Swift repository.
        mode must be inspect or modify.
        modify only when the user explicitly wants source code changed/fixed/implemented.
        path must be an EXACT repository path only if the user/context explicitly supplies one. Never invent a path.
        Return JSON only: {"mode":"inspect","path":null}

        RECENT CONTEXT
        \(recentHistory.suffix(5).promptTranscript)

        USER REQUEST
        \(command)
        """
        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 400)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let decision = try? JSONDecoder().decode(IntentDecision.self, from: data) else {
            return IntentDecision(mode: "inspect", path: nil)
        }
        return decision
    }

    private func proposeReplacement(
        path: String,
        request: String,
        recentHistory: [ChatMessage]
    ) async throws -> CapabilityOutcome {
        let snapshot = try await github.fetchFile(path: path)
        guard snapshot.content.count <= 90_000 else {
            return .reply("Το source file είναι πολύ μεγάλο (\(snapshot.content.count) chars) για ασφαλές full-file replacement σε ένα coding step. Χρειάζεται scoped patch pipeline.")
        }

        let prompt = """
        You are the coding implementation component of TRAVIS.
        Modify exactly ONE existing Swift/source file using the CURRENT FILE below as the canonical base.
        Implement only the requested change. Preserve unrelated behavior and formatting as much as practical.
        Never omit existing code with placeholders such as "...", "unchanged", or pseudocode.
        Return the COMPLETE replacement file between the exact markers <TRAVIS_FILE> and </TRAVIS_FILE>.
        After that return one line: COMMIT: <short imperative commit message>
        Do not return markdown fences.

        USER REQUEST
        \(request)

        RECENT CONTEXT
        \(recentHistory.suffix(5).promptTranscript)

        TARGET PATH
        \(path)

        CURRENT FILE SHA
        \(snapshot.sha)

        CURRENT COMPLETE FILE
        <CURRENT_FILE>
        \(snapshot.content)
        </CURRENT_FILE>
        """

        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 14000)
        guard let open = raw.range(of: "<TRAVIS_FILE>"),
              let close = raw.range(of: "</TRAVIS_FILE>", range: open.upperBound..<raw.endIndex) else {
            return .reply("Το coding model δεν επέστρεψε πλήρες replacement file, επομένως δεν δημιουργήθηκε mutation proposal.")
        }

        let replacement = String(raw[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty,
              !replacement.contains("<CURRENT_FILE>"),
              replacement.count > max(40, snapshot.content.count / 5) else {
            return .reply("Το replacement απέτυχε deterministic completeness checks. Δεν δημιουργήθηκε mutation proposal.")
        }

        let commitMessage: String = {
            guard let range = raw.range(of: "COMMIT:", options: .caseInsensitive, range: close.upperBound..<raw.endIndex) else {
                return "Update \((path as NSString).lastPathComponent)"
            }
            let value = raw[range.upperBound...].split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Update \((path as NSString).lastPathComponent)" : String(trimmed.prefix(180))
        }()

        let mutation = MutationPayload(
            path: path,
            expectedSHA: snapshot.sha,
            newContent: replacement,
            commitMessage: commitMessage
        )
        let payloadData = try JSONEncoder().encode(mutation)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            return .reply("Δεν μπόρεσα να κωδικοποιήσω με ασφάλεια το mutation proposal.")
        }

        let delta = replacement.count - snapshot.content.count
        let action = ProposedAction(
            capabilityId: id,
            summary: "Αλλαγή source file: \(path)",
            reasoning: "Η αλλαγή παράχθηκε πάνω στην τρέχουσα GitHub έκδοση του αρχείου και θα εφαρμοστεί μόνο αν το SHA παραμένει \(snapshot.sha.prefix(10)).",
            expectedImpact: "Full-file replacement στο branch \(github.branch). Character delta: \(delta). Αν το αρχείο άλλαξε στο μεταξύ, το GitHub SHA precondition θα απορρίψει το commit.",
            riskLevel: .high,
            payload: payload,
            filename: (path as NSString).lastPathComponent,
            location: path
        )
        return .proposal(action)
    }
}
