import Foundation

/// General HTTP/JSON capability for public API work.
/// GET/HEAD are read-only. Mutating methods are never executed directly;
/// they become ProposedAction so the existing approval system remains authoritative.
@MainActor
final class PublicAPICapability: AgentCapability {
    let id = "public_api"
    let name = "Public API"
    let capabilityDescription = "Καλεί δημόσια HTTP/JSON APIs. GET/HEAD εκτελούνται read-only· POST/PUT/PATCH/DELETE απαιτούν approval πριν από οποιαδήποτε εξωτερική mutation."
    let keywords: [String] = ["api", "endpoint", "json api", "http get", "rest api", "webhook"]
    private(set) var status: AgentCapabilityStatus = .idle

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .automation,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly, .externalMutation],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 90,
                maxAttempts: 2
            )
        )
    }

    private struct RequestSpec: Decodable {
        let method: String
        let url: String
        let headers: [String: String]?
        let body: String?
    }

    private let aiService: AIService

    init(aiService: AIService = .shared) {
        self.aiService = aiService
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let spec = try await extractRequest(from: command, recentHistory: recentHistory)
        let method = spec.method.uppercased()
        guard let url = URL(string: spec.url), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return .reply("Δεν μπόρεσα να εντοπίσω έγκυρο HTTP/HTTPS endpoint στην εντολή.")
        }

        if method == "GET" || method == "HEAD" {
            return try await executeRead(method: method, url: url, headers: spec.headers ?? [:])
        }

        let allowedMutations = ["POST", "PUT", "PATCH", "DELETE"]
        guard allowedMutations.contains(method) else {
            return .reply("Δεν υποστηρίζεται HTTP method \(method).")
        }

        let bodyPreview = String((spec.body ?? "").prefix(1000))
        let payloadObject: [String: String] = [
            "method": method,
            "url": url.absoluteString,
            "body": bodyPreview
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let payload = String(data: payloadData, encoding: .utf8)

        let action = ProposedAction(
            capabilityId: id,
            summary: "HTTP \(method) προς \(url.absoluteString)",
            reasoning: "Η κλήση μπορεί να αλλάξει εξωτερικό σύστημα, επομένως δεν εκτελείται χωρίς ρητή έγκριση.",
            expectedImpact: "Εξωτερική HTTP mutation στο συγκεκριμένο endpoint. Δεν έχει εκτελεστεί ακόμη.",
            riskLevel: method == "DELETE" ? .high : .medium,
            payload: payload
        )
        return .proposal(action)
    }

    func resolve(_ action: ProposedAction) {
        // External mutation executor is intentionally not implemented here yet.
        // Approval records intent; a dedicated credential-aware API executor will
        // perform the mutation in the integrations phase.
    }

    private func executeRead(method: String, url: URL, headers: [String: String]) async throws -> CapabilityOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (key, value) in headers where Self.isSafeReadHeader(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .reply("Το endpoint δεν επέστρεψε έγκυρη HTTP απάντηση.")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let clipped = data.prefix(120_000)
        let body: String
        if let object = try? JSONSerialization.jsonObject(with: Data(clipped)),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            body = string
        } else {
            body = String(data: Data(clipped), encoding: .utf8) ?? "<binary response: \(data.count) bytes>"
        }

        return .reply("""
        HTTP API RESULT
        URL: \(url.absoluteString)
        STATUS: \(http.statusCode)
        CONTENT-TYPE: \(contentType)
        BYTES: \(data.count)

        BODY
        \(body)
        \(data.count > clipped.count ? "\n[RESPONSE TRUNCATED TO 120000 BYTES]" : "")
        """)
    }

    private func extractRequest(from command: String, recentHistory: [ChatMessage]) async throws -> RequestSpec {
        let prompt = """
        Extract an HTTP request from the user's instruction. Do not invent a URL.
        If no method is explicit, use GET only when the user is clearly asking to read/fetch data.
        Never invent authentication headers, tokens, cookies or secrets.
        Return JSON only:
        {"method":"GET","url":"https://...","headers":{},"body":null}

        RECENT CONTEXT
        \(recentHistory.suffix(4).promptTranscript)

        USER REQUEST
        \(command)
        """
        let raw = try await aiService.generateText(prompt: prompt, maxTokens: 700)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let spec = try? JSONDecoder().decode(RequestSpec.self, from: data) else {
            throw APIExtractionError.invalidRequest
        }
        return spec
    }

    private static func isSafeReadHeader(_ key: String) -> Bool {
        let lower = key.lowercased()
        return !["authorization", "cookie", "proxy-authorization", "x-api-key"].contains(lower)
    }
}

private enum APIExtractionError: LocalizedError {
    case invalidRequest
    var errorDescription: String? { "Δεν μπόρεσα να μετατρέψω την εντολή σε ασφαλές HTTP request." }
}
