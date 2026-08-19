import Foundation

/// Strict zero-model parser for durable automation commands.
/// It only accepts exact IDs/timestamps and falls back when anything is ambiguous.
@MainActor
final class AutomationDeterministicCommandRouter {
    static let shared = AutomationDeterministicCommandRouter()

    func invocation(for command: String, capabilities: [AgentCapability]) -> DeterministicCapabilityInvocation? {
        guard capabilities.contains(where: { $0.id == "local_automation" }) else { return nil }

        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()

        let listMarkers = [
            "scheduled jobs", "automation jobs", "deferred work",
            "προγραμματισμενες εργασιες", "προγραμματισμένες εργασίες",
            "δειξε τις προγραμματισμενες εργασιες", "δείξε τις προγραμματισμένες εργασίες"
        ]
        if listMarkers.contains(where: { normalized.contains($0) }) {
            return DeterministicCapabilityInvocation(capabilityId: "local_automation", operation: "list")
        }

        let cancelMarkers = ["cancel scheduled", "cancel automation", "ακυρωσε προγραμματισμενη", "ακύρωσε προγραμματισμένη"]
        if cancelMarkers.contains(where: { normalized.contains($0) }), let id = firstUUID(in: command) {
            return DeterministicCapabilityInvocation(
                capabilityId: "local_automation",
                operation: "cancel",
                arguments: ["workId": id.uuidString]
            )
        }

        let scheduleMarkers = ["schedule task", "schedule autonomous task", "προγραμματισε task", "προγραμμάτισε task", "προγραμματισε εργασια", "προγραμμάτισε εργασία"]
        guard scheduleMarkers.contains(where: { normalized.contains($0) }) else { return nil }

        let ids = allUUIDs(in: command)
        guard let taskId = ids.first, let runAt = firstISO8601(in: command) else { return nil }

        var args: [String: String] = [
            "taskId": taskId.uuidString,
            "runAt": runAt
        ]
        if let title = quotedValues(in: command).first, !title.isEmpty { args["title"] = title }
        if let seconds = intervalSeconds(in: normalized), seconds >= 3600 { args["intervalSeconds"] = String(seconds) }

        return DeterministicCapabilityInvocation(
            capabilityId: "local_automation",
            operation: "schedule",
            arguments: args
        )
    }

    private func allUUIDs(in text: String) -> [UUID] {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            UUID(uuidString: ns.substring(with: $0.range))
        }
    }

    private func firstUUID(in text: String) -> UUID? { allUUIDs(in: text).first }

    private func firstISO8601(in text: String) -> String? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private func intervalSeconds(in normalized: String) -> Int? {
        let patterns: [(String, Int)] = [
            (#"every\s+(\d+)\s+hours?"#, 3600),
            (#"every\s+(\d+)\s+days?"#, 86_400),
            (#"καθε\s+(\d+)\s+ωρ"#, 3600),
            (#"κάθε\s+(\d+)\s+ωρ"#, 3600),
            (#"καθε\s+(\d+)\s+ημερ"#, 86_400),
            (#"κάθε\s+(\d+)\s+ημερ"#, 86_400)
        ]
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[range]) else { continue }
            return value * multiplier
        }
        return nil
    }

    private func quotedValues(in text: String) -> [String] {
        let pattern = #"[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
