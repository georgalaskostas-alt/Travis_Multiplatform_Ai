import Foundation

@MainActor
final class SelfAuditCapability: AgentCapability, DeterministicInvocableCapability, DeterministicInvocationPolicyProviding {
    let id = "self_audit"
    let name = "TRAVIS Self Audit"
    let capabilityDescription = "Read-only inspection of the TRAVIS repository for reliability, security, architecture, persistence and maintainability risks. Produces evidence-backed improvement recommendations; never edits code."
    let keywords = ["self audit","self-audit","audit travis","code audit","ελεγξε τον κωδικα σου","έλεγξε τον κώδικά σου","αυτοελεγχος","αυτοέλεγχος","audit κωδικα","audit κώδικα"]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .coding,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 90,
                maxAttempts: 3
            )
        )
    }

    func requiresApproval(for invocation: DeterministicCapabilityInvocation) -> Bool { false }
    func riskLevel(for invocation: DeterministicCapabilityInvocation) -> PlanStepRiskLevel { .low }
    func resolve(_ action: ProposedAction) {}

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        guard let path = explicitPath(in: command) else {
            return .reply("Για deterministic self-audit χρειάζομαι explicit path=/absolute/path προς το repository. Η επιθεώρηση είναι read-only· αλλαγές κώδικα παραμένουν approval-gated.")
        }
        return try await handle(invocation: .init(capabilityId: id, operation: "audit_repository", arguments: ["path": path]))
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        guard invocation.operation == "audit_repository", let raw = invocation.arguments["path"] else {
            return .reply("Unsupported self-audit operation.")
        }

        #if os(macOS)
        status = .running
        defer { status = .idle }
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard root.path == home.path || root.path.hasPrefix(home.path + "/") else {
            return .reply("Self-audit denied: repository path must remain inside the user home directory.")
        }
        let report = try scan(root: root)
        return .reply(report)
        #else
        return .reply("TRAVIS repository self-audit is executed by the macOS runtime. The iPhone companion can request and display the result, but does not scan the Mac filesystem directly.")
        #endif
    }

    #if os(macOS)
    private func scan(root: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile) }
        let allowed = Set(["swift","py","md","json","plist","sh"])
        var findings: [(Int,String,String)] = []
        var scanned = 0
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.fileSizeKey], options: [.skipsHiddenFiles]) else { return "SELF AUDIT\nUnable to enumerate repository." }
        for case let url as URL in e {
            if url.path.contains("/.git/") { continue }
            guard allowed.contains(url.pathExtension.lowercased()), let values = try? url.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? 0) <= 600_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let lower = text.lowercased()
            let isAuditImplementation = rel.hasSuffix("SelfAuditCapability.swift") || rel.contains("travis_runtime_worker_v")
            if !isAuditImplementation && (lower.contains("development-only safety net") || lower.contains("deletedefaultstore")) {
                findings.append((3,rel,"Destructive development persistence fallback detected; replace with versioned migration before production."))
            }
            if !isAuditImplementation && (lower.contains("fatalerror(") || lower.contains("preconditionfailure(")) {
                findings.append((2,rel,"Process-terminating failure path present; verify production recovery policy."))
            }
            if !isAuditImplementation && (lower.contains("todo") || lower.contains("fixme")) {
                findings.append((1,rel,"TODO/FIXME markers remain."))
            }
            if text.split(separator: "\n", omittingEmptySubsequences: false).count > 1200 { findings.append((2,rel,"Very large source file; candidate for decomposition/test isolation.")) }
            if !isAuditImplementation && containsLikelyCredentialLiteral(text) {
                findings.append((3,rel,"Possible credential literal assignment; inspect without exposing secret values."))
            }
        }
        findings.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        let high = findings.filter{$0.0==3}.count, medium=findings.filter{$0.0==2}.count, low=findings.filter{$0.0==1}.count
        let rows = findings.prefix(40).map { severity($0.0) + "  " + $0.1 + " — " + $0.2 }.joined(separator: "\n")
        return """
        TRAVIS SELF AUDIT — READ ONLY

        Repository: \(root.path)
        Scanned files: \(scanned)
        Findings: HIGH \(high) · MEDIUM \(medium) · LOW \(low)

        \(rows.isEmpty ? "No heuristic findings in scanned files." : rows)

        This audit can recommend changes autonomously. Applying code or GUI modifications remains a separately approval-gated action.
        """
    }

    private func containsLikelyCredentialLiteral(_ text: String) -> Bool {
        // Deliberately conservative: flag assignment-like source lines only.
        // Avoid matching documentation, scanner marker tables, Keychain account
        // names, or variable declarations such as apiKey/secret without a value.
        let keys = ["api_key", "apikey", "api-key", "password", "private_key", "private-key", "secret"]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("//"), !line.hasPrefix("#"), !line.isEmpty else { continue }
            let lower = line.lowercased()
            guard keys.contains(where: { lower.contains($0) }) else { continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let rhs = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            guard rhs.count >= 2, let quote = rhs.first, quote == "\"" || quote == "'" else { continue }
            let value = rhs.dropFirst().prefix { $0 != quote }
            guard value.count >= 8 else { continue }
            let normalized = value.lowercased()
            if normalized.contains("keychain") || normalized.contains("environment") || normalized.contains("placeholder") || normalized.contains("example") { continue }
            return true
        }
        return false
    }

    private func severity(_ rank: Int) -> String { rank == 3 ? "HIGH" : rank == 2 ? "MEDIUM" : "LOW" }
    #endif

    private func explicitPath(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == ";" }) {
            let s = String(token)
            guard s.hasPrefix("path=") else { continue }
            let value = String(s.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
