import Foundation

@MainActor
final class LocalDataCapability: AgentCapability, DeterministicInvocableCapability {
    let id = "local_data"
    let name = "Local Data"
    let capabilityDescription = "Zero-token local CSV/JSON inspection, filtering, projection and format conversion inside approved filesystem scope."
    let keywords = ["csv", "json", "δεδομένα", "data", "στήλες", "columns", "filter rows"]
    private(set) var status: AgentCapabilityStatus = .idle

    private let locations: FileLocationService
    private let maxBytes = 15_000_000
    private let maxRows = 100_000

    init(locations: FileLocationService? = nil) {
        self.locations = locations ?? FileLocationService.shared
    }

    var descriptor: CapabilityDescriptor {
        CapabilityDescriptor(
            id: id,
            displayName: name,
            summary: capabilityDescription,
            domain: .productivity,
            keywords: keywords,
            policy: CapabilityExecutionPolicy(
                declaredEffects: [.readOnly],
                permissionKeys: ["file_save"],
                requiresExplicitApproval: false,
                supportsBackgroundExecution: true,
                supportsProjectContext: true,
                timeoutSeconds: 45,
                maxAttempts: 1
            )
        )
    }

    func handle(command: String, recentHistory: [ChatMessage]) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        return .reply("Το local_data capability χρησιμοποιεί structured arguments ώστε οι εργασίες CSV/JSON να εκτελούνται τοπικά χωρίς AI tokens.")
    }

    func handle(invocation: DeterministicCapabilityInvocation) async throws -> CapabilityOutcome {
        status = .running
        defer { status = .idle }
        guard invocation.capabilityId == id else { return .reply("Wrong capability invocation.") }
        guard let rawPath = invocation.arguments["path"],
              let resolved = locations.resolveExistingPath(rawPath) else {
            return .reply("Το data file δεν υπάρχει μέσα στο εγκεκριμένο filesystem scope.")
        }
        defer { resolved.stopAccessing() }

        let data = try Data(contentsOf: resolved.url)
        guard data.count <= maxBytes else { return .reply("Το αρχείο υπερβαίνει το local safety limit των 15 MB.") }
        guard let text = String(data: data, encoding: .utf8) else { return .reply("Το αρχείο δεν είναι έγκυρο UTF-8.") }

        switch invocation.operation {
        case "csv_summary":
            return .reply(try csvSummary(text: text, file: resolved.url.lastPathComponent))
        case "csv_select":
            let columns = splitList(invocation.arguments["columns"])
            guard !columns.isEmpty else { return .reply("Missing columns.") }
            let limit = clampedLimit(invocation.arguments["limit"], fallback: 200)
            return .reply(try csvSelect(text: text, columns: columns, limit: limit))
        case "csv_filter":
            guard let column = invocation.arguments["column"],
                  let value = invocation.arguments["value"] else { return .reply("Missing column/value.") }
            let mode = invocation.arguments["mode"]?.lowercased() ?? "equals"
            let limit = clampedLimit(invocation.arguments["limit"], fallback: 500)
            return .reply(try csvFilter(text: text, column: column, value: value, mode: mode, limit: limit))
        case "csv_to_json":
            let limit = clampedLimit(invocation.arguments["limit"], fallback: 500)
            return .reply(try csvToJSON(text: text, limit: limit))
        case "json_pretty":
            return .reply(try jsonPretty(data: data))
        case "json_keys":
            return .reply(try jsonKeys(data: data))
        case "json_get":
            guard let keyPath = invocation.arguments["key_path"], !keyPath.isEmpty else { return .reply("Missing key_path.") }
            return .reply(try jsonGet(data: data, keyPath: keyPath))
        case "json_to_csv":
            let limit = clampedLimit(invocation.arguments["limit"], fallback: 500)
            return .reply(try jsonToCSV(data: data, limit: limit))
        default:
            return .reply("Unsupported local data operation: \(invocation.operation)")
        }
    }

    func resolve(_ action: ProposedAction) { }

    private func csvSummary(text: String, file: String) throws -> String {
        let table = try parseCSV(text)
        let headers = table.headers
        let sample = table.rows.prefix(5).map { row in
            headers.enumerated().map { index, header in "\(header)=\(index < row.count ? row[index] : "")" }.joined(separator: " | ")
        }.joined(separator: "\n")
        return """
        LOCAL DATA CSV SUMMARY

        file: \(file)
        rows: \(table.rows.count)
        columns: \(headers.count)
        headers: \(headers.joined(separator: " | "))

        SAMPLE
        \(sample.isEmpty ? "(empty)" : sample)
        """
    }

    private func csvSelect(text: String, columns: [String], limit: Int) throws -> String {
        let table = try parseCSV(text)
        let indices = try columns.map { name -> Int in
            guard let index = table.headers.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw DataError.unknownColumn(name)
            }
            return index
        }
        let rows = table.rows.prefix(limit).map { row in indices.map { $0 < row.count ? row[$0] : "" } }
        return structuredTable(title: "LOCAL DATA CSV SELECT", headers: columns, rows: rows)
    }

    private func csvFilter(text: String, column: String, value: String, mode: String, limit: Int) throws -> String {
        let table = try parseCSV(text)
        guard let index = table.headers.firstIndex(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) else {
            throw DataError.unknownColumn(column)
        }
        let filtered = table.rows.filter { row in
            let cell = index < row.count ? row[index] : ""
            switch mode {
            case "contains": return cell.localizedCaseInsensitiveContains(value)
            case "prefix": return cell.lowercased().hasPrefix(value.lowercased())
            case "suffix": return cell.lowercased().hasSuffix(value.lowercased())
            case "not_equals": return cell.caseInsensitiveCompare(value) != .orderedSame
            default: return cell.caseInsensitiveCompare(value) == .orderedSame
            }
        }
        return structuredTable(title: "LOCAL DATA CSV FILTER", headers: table.headers, rows: Array(filtered.prefix(limit)), extra: "matched: \(filtered.count)")
    }

    private func csvToJSON(text: String, limit: Int) throws -> String {
        let table = try parseCSV(text)
        let objects: [[String: String]] = table.rows.prefix(limit).map { row in
            Dictionary(uniqueKeysWithValues: table.headers.enumerated().map { index, header in
                (header, index < row.count ? row[index] : "")
            })
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        return "LOCAL DATA JSON\n\n" + (String(data: data, encoding: .utf8) ?? "[]")
    }

    private func jsonPretty(data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return "LOCAL DATA JSON PRETTY\n\n" + (String(data: pretty, encoding: .utf8) ?? "")
    }

    private func jsonKeys(data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let keys: [String]
        if let dictionary = object as? [String: Any] {
            keys = dictionary.keys.sorted()
        } else if let array = object as? [[String: Any]], let first = array.first {
            keys = first.keys.sorted()
        } else {
            keys = []
        }
        return "LOCAL DATA JSON KEYS\n\ncount: \(keys.count)\n" + keys.joined(separator: "\n")
    }

    private func jsonGet(data: Data, keyPath: String) throws -> String {
        var current: Any = try JSONSerialization.jsonObject(with: data)
        for token in keyPath.split(separator: ".").map(String.init) {
            if let dictionary = current as? [String: Any], let next = dictionary[token] {
                current = next
            } else if let array = current as? [Any], let index = Int(token), array.indices.contains(index) {
                current = array[index]
            } else {
                throw DataError.unknownKeyPath(keyPath)
            }
        }
        let output: String
        if JSONSerialization.isValidJSONObject(current) {
            let encoded = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
            output = String(data: encoded, encoding: .utf8) ?? ""
        } else {
            output = String(describing: current)
        }
        return "LOCAL DATA JSON VALUE\n\nkey_path: \(keyPath)\n\n\(output)"
    }

    private func jsonToCSV(data: Data, limit: Int) throws -> String {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DataError.jsonArrayRequired
        }
        let keys = Array(Set(array.flatMap { $0.keys })).sorted()
        let rows = array.prefix(limit).map { object in keys.map { csvScalar(object[$0]) } }
        return structuredTable(title: "LOCAL DATA CSV", headers: keys, rows: rows)
    }

    private func structuredTable(title: String, headers: [String], rows: [[String]], extra: String? = nil) -> String {
        var lines = [title, "", "columns: " + headers.joined(separator: " | ")]
        if let extra { lines.append(extra) }
        lines.append("rows: \(rows.count)")
        lines.append("")
        lines.append(headers.map(escapeCell).joined(separator: ","))
        lines.append(contentsOf: rows.map { $0.map(escapeCell).joined(separator: ",") })
        return lines.joined(separator: "\n")
    }

    private func parseCSV(_ text: String) throws -> (headers: [String], rows: [[String]]) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if inQuotes, index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                else { inQuotes.toggle() }
            } else if char == ",", !inQuotes {
                row.append(field); field = ""
            } else if (char == "\n" || char == "\r"), !inQuotes {
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
                if rows.count > maxRows + 1 { throw DataError.tooManyRows }
            } else {
                field.append(char)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let header = rows.first, !header.isEmpty else { throw DataError.emptyCSV }
        return (header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, Array(rows.dropFirst()))
    }

    private func splitList(_ value: String?) -> [String] {
        value?.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
    }

    private func clampedLimit(_ value: String?, fallback: Int) -> Int {
        min(max(Int(value ?? "") ?? fallback, 1), 5_000)
    }

    private func escapeCell(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func csvScalar(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) { return string }
        return String(describing: value)
    }

    private enum DataError: LocalizedError {
        case emptyCSV
        case tooManyRows
        case unknownColumn(String)
        case unknownKeyPath(String)
        case jsonArrayRequired

        var errorDescription: String? {
            switch self {
            case .emptyCSV: return "Το CSV δεν περιέχει header row."
            case .tooManyRows: return "Το CSV υπερβαίνει το local safety limit των 100.000 rows."
            case .unknownColumn(let name): return "Δεν βρέθηκε η στήλη '\(name)'."
            case .unknownKeyPath(let path): return "Δεν βρέθηκε το JSON key path '\(path)'."
            case .jsonArrayRequired: return "Για JSON → CSV απαιτείται top-level array από objects."
            }
        }
    }
}
