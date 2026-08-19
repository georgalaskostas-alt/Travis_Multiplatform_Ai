import Foundation

@MainActor
final class FCCAssistantCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "fcc_assistant"
    let name = "FCC Assistant"
    let capabilityDescription = "Read-only local bridge to the FCC Assistant backend for PI data, reports and FCC analysis."
    let keywords = ["fcc", "pi", "shift report", "tag", "refinery", "μονάδα", "βάρδια"]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .data,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: [],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 120,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        let normalized = command.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        if normalized.contains("status") || normalized.contains("κατασταση") {
            return try await handle(invocation: .init(capabilityId: id, operation: "status"))
        }
        if normalized.contains("demo") && normalized.contains("shift") {
            return try await handle(invocation: .init(capabilityId: id, operation: "demo_shift"))
        }
        return .reply("Το FCC module είναι διαθέσιμο. Για πλήρη ανάλυση χρησιμοποίησε structured FCC mission ή άνοιξε το FCC window στο Command Center.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong FCC invocation.") }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        switch invocation.operation {
        case "status":
            return .reply(try await get(path: "/health"))
        case "capabilities":
            return .reply(try await get(path: "/api/v1/system/capabilities"))
        case "demo_shift":
            return .reply(try await get(path: "/api/v1/simulator/demo-shift"))
        case "list_tags":
            return .reply(try await get(path: "/api/v1/tags"))
        case "shift_report":
            guard let start = invocation.arguments["start_time"], let end = invocation.arguments["end_time"] else { return .reply("Missing start_time/end_time.") }
            var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/reports/shift"), resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "startTime", value: start), URLQueryItem(name: "endTime", value: end)]
            if let tags = invocation.arguments["tags"], !tags.isEmpty { items.append(URLQueryItem(name: "tags", value: tags)) }
            components.queryItems = items
            return .reply(try await request(url: components.url!))
        case "ask_shift":
            guard let question = invocation.arguments["question"], let start = invocation.arguments["start_time"], let end = invocation.arguments["end_time"] else { return .reply("Missing FCC question/start/end.") }
            let body: [String: Any] = ["question": question, "start_time": start, "end_time": end, "tags": invocation.arguments["tags"]?.split(separator: ",").map { String($0) } ?? NSNull()]
            return .reply(try await post(path: "/api/v1/assistant/shift", body: body))
        case "ask_tag":
            guard let question = invocation.arguments["question"], let tag = invocation.arguments["tag_key"], let start = invocation.arguments["start_time"], let end = invocation.arguments["end_time"] else { return .reply("Missing FCC tag question arguments.") }
            return .reply(try await post(path: "/api/v1/assistant/tag", body: ["question":question,"tag_key":tag,"start_time":start,"end_time":end]))
        default:
            return .reply("Unsupported FCC operation: \(invocation.operation)")
        }
    }

    func resolve(_ action: ProposedAction) {}

    private func get(path: String) async throws -> String {
        try await request(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
    }

    private func post(path: String, body: [String: Any]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await requestText(request)
    }

    private func request(url: URL) async throws -> String {
        try await requestText(URLRequest(url: url))
    }

    private func requestText(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
