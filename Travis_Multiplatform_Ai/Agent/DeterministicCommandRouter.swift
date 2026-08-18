import Foundation

/// Conservative local parser for single-step computer-work operations.
/// It never invents a path or mutation argument. If the command cannot be
/// represented exactly, it returns nil and the normal semantic/AI path remains
/// responsible for understanding the request.
@MainActor
final class DeterministicCommandRouter {
    static let shared = DeterministicCommandRouter()

    func invocation(for command: String, capabilities: [AgentCapability]) -> DeterministicCapabilityInvocation? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el_GR"))
            .lowercased()
        let available = Set(capabilities.map(\.id))
        let paths = absolutePaths(in: command)

        if available.contains("local_file_search"), let invocation = fileSearch(command: command, normalized: normalized, paths: paths) {
            return invocation
        }
        if available.contains("local_documents"), let invocation = document(command: command, normalized: normalized, paths: paths) {
            return invocation
        }
        return nil
    }

    private func fileSearch(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        let searchMarkers = ["find files", "search files", "filter files", "βρες αρχεία", "βρες αρχεια", "αναζήτηση αρχείων", "αναζητηση αρχειων"]
        guard searchMarkers.contains(where: { normalized.contains($0) }), let path = paths.first else { return nil }
        var arguments: [String: String] = ["path": path, "recursive": normalized.contains("recursive") || normalized.contains("αναδρομ") ? "true" : "false"]
        if let ext = explicitExtension(in: command) { arguments["extension"] = ext }
        if let limit = integer(afterAny: ["limit", "όριο", "οριο"], in: normalized) { arguments["limit"] = String(min(max(limit, 1), 1000)) }
        return DeterministicCapabilityInvocation(capabilityId: "local_file_search", operation: "search", arguments: arguments)
    }

    private func document(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        guard let path = paths.first else { return nil }

        if normalized.contains("document stats") || normalized.contains("file stats") || normalized.contains("στατιστικ") {
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "stats", arguments: ["path": path])
        }

        if normalized.contains("head") || normalized.contains("πρωτες γραμμ") || normalized.contains("πρώτες γραμμ") {
            var args = ["path": path]
            if let lines = integer(afterAny: ["head", "γραμμές", "γραμμες"], in: normalized) { args["lines"] = String(min(max(lines, 1), 500)) }
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "head", arguments: args)
        }

        if normalized.contains("find in file") || normalized.contains("search in file") || normalized.contains("βρες στο αρχείο") || normalized.contains("βρες στο αρχειο") {
            let quoted = quotedValues(in: command)
            guard let query = quoted.first, !query.isEmpty else { return nil }
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "find", arguments: ["path": path, "query": query])
        }

        if normalized.contains("normalize whitespace") || (normalized.contains("κανονικοποι") && normalized.contains("κενα")) {
            var args = ["path": path]
            if paths.count >= 2 { args["output_path"] = paths[1] }
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_normalized", arguments: args)
        }

        if normalized.contains("replace") || normalized.contains("αντικαταστ") {
            let quoted = quotedValues(in: command)
            guard quoted.count >= 2, !quoted[0].isEmpty else { return nil }
            var args = ["path": path, "find": quoted[0], "replace": quoted[1]]
            if paths.count >= 2 { args["output_path"] = paths[1] }
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_replace", arguments: args)
        }

        return nil
    }

    private func absolutePaths(in text: String) -> [String] {
        let pattern = #"/Users/[^\s\n\r\t,;]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}.!?"))
        }
    }

    private func explicitExtension(in text: String) -> String? {
        let pattern = #"\.([A-Za-z0-9]{1,10})(?:\s|$|,|;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).lowercased()
    }

    private func quotedValues(in text: String) -> [String] {
        let pattern = #"[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func integer(afterAny markers: [String], in text: String) -> Int? {
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let tail = text[range.upperBound...]
            if let token = tail.split(whereSeparator: { !$0.isNumber }).first, let value = Int(token) { return value }
        }
        return nil
    }
}
