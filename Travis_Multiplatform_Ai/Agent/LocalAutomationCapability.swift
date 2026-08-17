import Foundation

@MainActor
final class LocalAutomationCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_automation"
    let name = "Local Automation"
    let capabilityDescription = "Deterministic inspection and approval-gated creation/cancellation of durable deferred work items."
    let keywords: [String] = [
        "scheduled jobs", "automation jobs", "deferred work", "προγραμματισμενες εργασιες", "προγραμματισμένες εργασίες"
    ]
    private(set) var status: AgentCapabilityStatus = .idle
    var onExecutionUpdate: ((String) -> Void)?

    private let store: DeferredWorkStore

    init(store: DeferredWorkStore = .shared) {
        self.store = store
    }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .automation,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly, .localMutation],
                permissionKeys: [],
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 30,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }

        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()

        if normalized.contains("scheduled jobs") || normalized.contains("automation jobs") || normalized.contains("deferred work") || normalized.contains("προγραμματισμενες εργασιες") {
            return try await handle(invocation: DeterministicCapabilityInvocation(capabilityId: id, operation: "list"))
        }

        return .reply("Για deterministic automation χρησιμοποίησε structured task scheduling ή ζήτησε να εμφανιστούν οι προγραμματισμένες εργασίες. Η φυσική γλώσσα scheduling συνεχίζει να εξυπηρετείται από το dedicated scheduling router.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        guard invocation.capabilityId == id else {
            return .reply("Το structured invocation δεν ανήκει στο local_automation capability.")
        }
        LocalIntelligenceMetrics.shared.record(.structuredCapabilityExecution)

        switch invocation.operation {
        case "list":
            return .reply(try renderList())

        case "schedule":
            guard let taskIdText = invocation.arguments["taskId"],
                  let taskId = UUID(uuidString: taskIdText),
                  let runAtText = invocation.arguments["runAt"],
                  let runAt = Self.iso8601.date(from: runAtText) else {
                return .reply("Structured schedule requires valid taskId and ISO-8601 runAt.")
            }
            let interval = invocation.arguments["intervalSeconds"].flatMap(TimeInterval.init)
            let payload = MutationPayload(
                operation: "schedule",
                taskId: taskId,
                title: invocation.arguments["title"] ?? "TRAVIS scheduled task",
                runAt: runAt,
                intervalSeconds: interval,
                workId: nil
            )
            return try proposal(for: payload, summary: "Schedule autonomous task")

        case "cancel":
            guard let workIdText = invocation.arguments["workId"],
                  let workId = UUID(uuidString: workIdText) else {
                return .reply("Structured cancel requires a valid deferred-work ID.")
            }
            let payload = MutationPayload(operation: "cancel", taskId: nil, title: nil, runAt: nil, intervalSeconds: nil, workId: workId)
            return try proposal(for: payload, summary: "Cancel scheduled work")

        default:
            return .reply("Μη υποστηριζόμενη automation operation: \(invocation.operation)")
        }
    }

    func resolve(_ action: ProposedAction) {
        guard action.status == .approved,
              let raw = action.payload,
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder.iso8601.decode(MutationPayload.self, from: data) else { return }

        do {
            var items = try store.load()
            switch payload.operation {
            case "schedule":
                guard let taskId = payload.taskId, let runAt = payload.runAt else { return }
                let recurrence: DeferredWorkRecurrence
                if let interval = payload.intervalSeconds, interval >= 3600 {
                    recurrence = .interval(seconds: interval)
                } else {
                    recurrence = .none
                }
                let item = DeferredWorkItem(
                    taskId: taskId,
                    title: payload.title ?? "TRAVIS scheduled task",
                    runAt: runAt,
                    recurrence: recurrence
                )
                items.append(item)
                try store.save(items)
                onExecutionUpdate?("✅ Scheduled work created: \(String(item.id.uuidString.prefix(8))) at \(Self.iso8601.string(from: runAt)).")

            case "cancel":
                guard let workId = payload.workId,
                      let index = items.firstIndex(where: { $0.id == workId }) else {
                    onExecutionUpdate?("❌ Scheduled work item not found.")
                    return
                }
                items[index].status = .cancelled
                items[index].updatedAt = Date()
                try store.save(items)
                onExecutionUpdate?("✅ Scheduled work cancelled: \(String(workId.uuidString.prefix(8))).")

            default:
                return
            }
        } catch {
            onExecutionUpdate?("❌ Automation mutation failed: \(error.localizedDescription)")
        }
    }

    private struct MutationPayload: Codable {
        let operation: String
        let taskId: UUID?
        let title: String?
        let runAt: Date?
        let intervalSeconds: TimeInterval?
        let workId: UUID?
    }

    private func proposal(for payload: MutationPayload, summary: String) throws -> CapabilityOutcome {
        let data = try JSONEncoder.iso8601.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            return .reply("Απέτυχε η κωδικοποίηση automation proposal.")
        }
        return .proposal(ProposedAction(
            capabilityId: id,
            summary: summary,
            reasoning: "Η durable scheduling state αλλάζει μόνο μετά από explicit approval.",
            expectedImpact: payload.operation == "schedule"
                ? "Θα δημιουργηθεί durable deferred-work item για task \(payload.taskId?.uuidString ?? "unknown")."
                : "Θα ακυρωθεί το deferred-work item \(payload.workId?.uuidString ?? "unknown").",
            riskLevel: .low,
            payload: text,
            filename: nil,
            location: "TRAVIS deferred-work store"
        ))
    }

    private func renderList() throws -> String {
        let items = try store.load().sorted { $0.effectiveRunAt < $1.effectiveRunAt }
        guard !items.isEmpty else { return "Δεν υπάρχουν durable scheduled work items." }
        let rows = items.prefix(100).map { item in
            let recurrence: String
            switch item.recurrence {
            case .none: recurrence = "once"
            case .interval(let seconds): recurrence = "every \(Int(seconds))s"
            }
            return "\(String(item.id.uuidString.prefix(8))) [\(item.status.rawValue)] task=\(String(item.taskId.uuidString.prefix(8))) at=\(Self.iso8601.string(from: item.effectiveRunAt)) \(recurrence) — \(item.title)"
        }.joined(separator: "\n")
        return "DURABLE AUTOMATION JOBS\n\n\(rows)"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
