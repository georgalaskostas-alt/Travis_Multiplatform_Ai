import Foundation

/// V6 self-evolution pipeline for TRAVIS's own source code.
/// Read/analysis may be autonomous. Every mutation is isolated on a fresh branch,
/// SHA-guarded, approval-gated and NEVER merged automatically.
@MainActor
final class SelfEvolutionCapabilityV6: AgentCapability {
    let id = "self_evolution_v6"
    let name = "Self Evolution V6"
    let capabilityDescription = "Inspects TRAVIS source and can prepare an exact one-file improvement or GUI change on an isolated GitHub branch. Mutation requires approval; merge is never automatic."
    let keywords = ["self evolution", "self-evolution", "αυτοβελτίωση", "αυτοβελτιωση", "άλλαξε το gui", "αλλαξε το gui", "βελτίωσε τον travis", "βελτιωσε τον travis", "βελτίωσε τον κώδικα", "βελτιωσε τον κωδικα"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let aiService: AIService
    private let github: GitHubCodingService
    private let repositoryContext: RepositoryContextCapability

    init(aiService: AIService = .shared, github: GitHubCodingService = .shared, repositoryContext: RepositoryContextCapability? = nil) {
        self.aiService = aiService
        self.github = github
        self.repositoryContext = repositoryContext ?? RepositoryContextCapability()
    }

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
                requiresExplicitApproval: true,
                supportsBackgroundExecution: false,
                supportsProjectContext: true,
                timeoutSeconds: 240,
                maxAttempts: 2
            ),
            version: 2,
            inputSchema: ["path": "exact repository path using path=...", "request": "desired self/GUI improvement"],
            outputKinds: [.code, .file],
            costClass: .cloudReasoning,
            deterministicWhenStructured: false,
            freshnessSensitive: true
        )
    }

    private struct MutationPayload: Codable {
        let baseBranch: String
        let targetBranch: String
        let path: String
        let expectedBaseFileSHA: String
        let newContent: String
        let commitMessage: String
        let rationale: String
        let validationPlan: [String]
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        guard let path = Self.explicitValue(prefix: "path=", in: command) else {
            let inspection = try await repositoryContext.handle(
                command: "Inspect the TRAVIS repository for the source areas relevant to this self-improvement request. Do not modify anything. Request: \(command)",
                recentHistory: Array(recentHistory.suffix(4))
            )
            if case .reply(let text) = inspection {
                return .reply("""
                SELF-EVOLUTION V6 · DISCOVERY

                \(text)

                Mutation was NOT attempted. A self-change requires a grounded exact target path. Continue with path=<repository/path> after inspection identifies the canonical file.
                """)
            }
            return inspection
        }

        guard Self.isAllowedMutationPath(path) else {
            return .reply("SELF-EVOLUTION V6 blocked this target deterministically. Approval, risk, kill-switch, credential, signing, entitlement and Xcode project-control files cannot be self-mutated by this capability.")
        }

        let baseBranch = github.branch
        let snapshot = try await github.fetchFile(path: path, ref: baseBranch)
        guard snapshot.content.count <= 100_000 else {
            return .reply("SELF-EVOLUTION V6 stopped before mutation: target file is too large for a safe one-file full replacement. Use a scoped multi-file evolution plan instead.")
        }

        let reflection = CognitiveReflectionStore.shared.compactContext(goal: command, projectId: AIExecutionScope.context.projectId)
        let prompt = """
        You are TRAVIS V6 Self-Evolution Engineer working on TRAVIS's own Swift codebase.
        Produce a COMPLETE replacement for exactly one existing source file.

        HARD RULES
        - CURRENT FILE below is canonical. Preserve unrelated behavior.
        - Swift/SwiftUI/@Observable/@MainActor architecture only where applicable.
        - Never add hidden credentials, disable approval gates, weaken trading risk controls, disable kill switches, or create self-merging behavior.
        - GUI changes must preserve the established premium navy/cyan TRAVIS shell unless the user explicitly requests a visual redesign.
        - Do not edit project.pbxproj, entitlements, signing configuration, credential stores, approval gates, risk kernels, or kill-switch control paths.
        - No placeholders, ellipses, pseudocode or omitted existing code.
        - The result will be committed only to an isolated improvement branch after explicit approval.
        - Return exactly: <TRAVIS_FILE>complete file</TRAVIS_FILE>, then JSON between <META>...</META> with commitMessage, rationale, validationPlan[string].

        USER REQUEST
        \(command)

        VERIFIED REFLECTIONS
        \(reflection.isEmpty ? "None" : reflection)

        TARGET PATH
        \(path)

        CURRENT FILE SHA
        \(snapshot.sha)

        <CURRENT_FILE>
        \(snapshot.content)
        </CURRENT_FILE>
        """
        let context = AIInvocationContext(
            workload: .frontier,
            capabilityId: id,
            taskId: AIExecutionScope.context.taskId,
            stepId: AIExecutionScope.context.stepId,
            projectId: AIExecutionScope.context.projectId,
            operation: "self_evolution.propose"
        )
        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 16_000, context: context)
        guard let fileOpen = raw.range(of: "<TRAVIS_FILE>"),
              let fileClose = raw.range(of: "</TRAVIS_FILE>", range: fileOpen.upperBound..<raw.endIndex),
              let metaOpen = raw.range(of: "<META>", range: fileClose.upperBound..<raw.endIndex),
              let metaClose = raw.range(of: "</META>", range: metaOpen.upperBound..<raw.endIndex) else {
            return .reply("SELF-EVOLUTION V6 rejected the model output because it did not contain a complete replacement + validation metadata.")
        }

        let replacement = String(raw[fileOpen.upperBound..<fileClose.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksComplete(replacement, comparedTo: snapshot.content),
              !Self.containsForbiddenSecurityWeakening(replacement) else {
            return .reply("SELF-EVOLUTION V6 deterministic safety/completeness validation rejected the proposed replacement.")
        }

        let metaText = String(raw[metaOpen.upperBound..<metaClose.lowerBound])
        guard let metaData = metaText.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            return .reply("SELF-EVOLUTION V6 could not validate proposal metadata.")
        }
        let commit = (meta["commitMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Improve \((path as NSString).lastPathComponent)"
        let rationale = (meta["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "TRAVIS-generated isolated self-improvement"
        let validation = (meta["validationPlan"] as? [String]) ?? ["Build macOS target", "Build iOS target", "Run affected runtime acceptance tests"]
        let target = github.improvementBranchName(seed: commit)
        let payload = MutationPayload(
            baseBranch: baseBranch,
            targetBranch: target,
            path: path,
            expectedBaseFileSHA: snapshot.sha,
            newContent: replacement,
            commitMessage: String(commit.prefix(180)),
            rationale: String(rationale.prefix(4_000)),
            validationPlan: Array(validation.prefix(12))
        )
        let encoded = try JSONEncoder().encode(payload)
        guard let payloadText = String(data: encoded, encoding: .utf8) else { return .none }
        return .proposal(ProposedAction(
            capabilityId: id,
            summary: "Self-evolution on isolated branch: \(path)",
            reasoning: "\(rationale)\nTarget branch: \(target)\nValidation: \(validation.joined(separator: " · "))",
            expectedImpact: "Creates branch \(target) from \(baseBranch) and commits one SHA-guarded replacement. It does NOT merge into the working branch.",
            riskLevel: .high,
            payload: payloadText,
            filename: (path as NSString).lastPathComponent,
            location: path
        ))
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let raw = action.payload,
              let data = raw.data(using: .utf8),
              let mutation = try? JSONDecoder().decode(MutationPayload.self, from: data),
              Self.isAllowedMutationPath(mutation.path),
              Self.looksComplete(mutation.newContent, comparedTo: mutation.newContent),
              !Self.containsForbiddenSecurityWeakening(mutation.newContent) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onExecutionUpdate?("🧬 SELF-EVOLUTION: creating isolated branch \(mutation.targetBranch)…")
            do {
                _ = try await self.github.createBranch(name: mutation.targetBranch, from: mutation.baseBranch)
                let current = try await self.github.fetchFile(path: mutation.path, ref: mutation.targetBranch)
                guard current.sha == mutation.expectedBaseFileSHA else {
                    self.onExecutionUpdate?("🛡️ SELF-EVOLUTION aborted: target file changed after proposal; SHA precondition failed.")
                    return
                }

                let commitSHA = try await self.github.replaceFile(
                    path: mutation.path,
                    expectedSHA: current.sha,
                    newContent: mutation.newContent,
                    commitMessage: mutation.commitMessage,
                    branchOverride: mutation.targetBranch
                )

                let verification = try await self.github.fetchFile(path: mutation.path, ref: mutation.targetBranch)
                guard verification.sha != current.sha,
                      verification.content.trimmingCharacters(in: .whitespacesAndNewlines) == mutation.newContent.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    self.onExecutionUpdate?("🛡️ SELF-EVOLUTION post-commit verification failed. Candidate remains isolated and must not be merged.")
                    return
                }

                self.onExecutionUpdate?("✅ SELF-EVOLUTION candidate committed and content-verified on isolated branch only: \(mutation.targetBranch) · \(String(commitSHA.prefix(10)))\nValidation still required before any merge: \(mutation.validationPlan.joined(separator: " · "))")
            } catch {
                self.onExecutionUpdate?("❌ SELF-EVOLUTION candidate failed safely: \(error.localizedDescription)")
            }
        }
    }

    private static func explicitValue(prefix: String, in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
            let value = String(token)
            guard value.hasPrefix(prefix) else { continue }
            let candidate = String(value.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !candidate.isEmpty { return candidate }
        }
        return nil
    }

    private static func isAllowedMutationPath(_ path: String) -> Bool {
        let normalized = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("..") else { return false }
        let protectedFragments = [
            "project.pbxproj", ".entitlements", "keychainservice", "approvalgate", "agentpolicyengine",
            "tradingriskkernel", "tradingsafetyenvelope", "worker-control", "killswitch", "kill-switch",
            "proposedaction", "permission", "signing", "credential", "secret", "apikey", "api_key"
        ]
        return !protectedFragments.contains(where: normalized.contains)
    }

    private static func looksComplete(_ replacement: String, comparedTo original: String) -> Bool {
        guard replacement.count > max(80, original.count / 5) else { return false }
        let lower = replacement.lowercased()
        let blocked = ["<current_file>", "... unchanged", "todo: existing code", "rest of file unchanged", "existing code here"]
        return !blocked.contains(where: lower.contains)
    }

    private static func containsForbiddenSecurityWeakening(_ content: String) -> Bool {
        let lower = content.lowercased()
        let forbidden = [
            "requiresexplicitapproval: false",
            "livetrading: true",
            "withdrawals: true",
            "killswitch = false",
            "killSwitch = false".lowercased(),
            "disable approval",
            "bypass approval"
        ]
        return forbidden.contains(where: lower.contains)
    }
}
