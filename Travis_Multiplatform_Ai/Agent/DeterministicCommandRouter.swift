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

        if available.contains("advanced_filesystem"), let invocation = advancedFilesystem(command: command, normalized: normalized, paths: paths) { return invocation }
        if available.contains("local_file_search"), let invocation = fileSearch(command: command, normalized: normalized, paths: paths) { return invocation }
        if available.contains("local_directory_analysis"), let invocation = directoryAnalysis(normalized: normalized, paths: paths) { return invocation }
        if available.contains("local_data"), let invocation = localData(command: command, normalized: normalized, paths: paths) { return invocation }
        if available.contains("local_artifact"), let invocation = localArtifact(command: command, normalized: normalized, paths: paths) { return invocation }
        if available.contains("local_documents"), let invocation = document(command: command, normalized: normalized, paths: paths) { return invocation }
        return nil
    }

    private func advancedFilesystem(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        let createMarkers = ["create folder", "new folder", "δημιουργησε φακελο", "δημιουργία φακέλου", "φτιαξε φακελο"]
        if createMarkers.contains(where: { normalized.contains($0) }), let parent = paths.first {
            let quoted = quotedValues(in: command)
            guard let folderName = quoted.first, isSafeSimpleName(folderName) else { return nil }
            return DeterministicCapabilityInvocation(capabilityId: "advanced_filesystem", operation: "create_folder", arguments: ["sourcePath": parent, "folderName": folderName])
        }

        let moveMarkers = ["move files", "move all", "μετακινησε", "μεταφερε", "μετακίνησε", "μετέφερε"]
        let copyMarkers = ["copy files", "copy all", "αντιγραψε", "αντίγραψε"]
        let deleteMarkers = ["delete files", "delete all", "διαγραψε", "διεγραψε", "διέγραψε"]
        let wantsMove = moveMarkers.contains(where: { normalized.contains($0) })
        let wantsCopy = copyMarkers.contains(where: { normalized.contains($0) })
        let wantsDelete = deleteMarkers.contains(where: { normalized.contains($0) })
        guard [wantsMove, wantsCopy, wantsDelete].filter({ $0 }).count == 1 else { return nil }

        if wantsDelete {
            guard let source = paths.first else { return nil }
            var args = ["sourcePath": source]
            if let ext = explicitExtension(in: command) { args["matchExtension"] = ext }
            else {
                let quoted = quotedValues(in: command).filter(isSafeSimpleName)
                guard !quoted.isEmpty else { return nil }
                args["names"] = quoted.joined(separator: "|")
            }
            return DeterministicCapabilityInvocation(capabilityId: "advanced_filesystem", operation: "delete", arguments: args)
        }

        guard paths.count >= 2 else { return nil }
        var args = ["sourcePath": paths[0], "destinationPath": paths[1]]
        if let ext = explicitExtension(in: command) { args["matchExtension"] = ext }
        else {
            let quoted = quotedValues(in: command).filter(isSafeSimpleName)
            guard !quoted.isEmpty else { return nil }
            args["names"] = quoted.joined(separator: "|")
        }
        return DeterministicCapabilityInvocation(capabilityId: "advanced_filesystem", operation: wantsMove ? "move" : "copy", arguments: args)
    }

    private func fileSearch(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        let searchMarkers = ["find files", "search files", "filter files", "βρες αρχεία", "βρες αρχεια", "αναζήτηση αρχείων", "αναζητηση αρχειων"]
        guard searchMarkers.contains(where: { normalized.contains($0) }), let path = paths.first else { return nil }
        var arguments: [String: String] = ["path": path, "recursive": normalized.contains("recursive") || normalized.contains("αναδρομ") ? "true" : "false"]
        if let ext = explicitExtension(in: command) { arguments["extension"] = ext }
        if let limit = integer(afterAny: ["limit", "όριο", "οριο"], in: normalized) { arguments["limit"] = String(min(max(limit, 1), 1000)) }
        return DeterministicCapabilityInvocation(capabilityId: "local_file_search", operation: "search", arguments: arguments)
    }

    private func directoryAnalysis(normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        guard let path = paths.first else { return nil }
        let operation: String
        if normalized.contains("duplicate files") || normalized.contains("find duplicates") || normalized.contains("διπλοτυπα αρχεια") || normalized.contains("διπλοτυπ") {
            operation = "duplicates"
        } else if normalized.contains("largest files") || normalized.contains("biggest files") || normalized.contains("μεγαλυτερα αρχεια") || normalized.contains("μεγαλύτερα αρχεία") {
            operation = "largest_files"
        } else if normalized.contains("extension summary") || normalized.contains("types of files") || normalized.contains("ανα επεκταση") || normalized.contains("ανά επέκταση") {
            operation = "extension_summary"
        } else if normalized.contains("folder inventory") || normalized.contains("directory inventory") || normalized.contains("απογραφη φακελου") || normalized.contains("ανάλυση φακέλου") || normalized.contains("αναλυση φακελου") {
            operation = "inventory"
        } else {
            return nil
        }
        var args = ["path": path, "recursive": normalized.contains("non recursive") || normalized.contains("μη αναδρομ") ? "false" : "true"]
        if operation == "largest_files", let limit = integer(afterAny: ["top", "limit", "πρωτα", "πρώτα"], in: normalized) {
            args["limit"] = String(min(max(limit, 1), 200))
        }
        return DeterministicCapabilityInvocation(capabilityId: "local_directory_analysis", operation: operation, arguments: args)
    }

    private func localData(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        guard let path = paths.first else { return nil }
        let lowerPath = path.lowercased()
        let quoted = quotedValues(in: command)
        var args = ["path": path]
        if let limit = integer(afterAny: ["limit", "όριο", "οριο", "rows", "γραμμες", "γραμμές"], in: normalized) {
            args["limit"] = String(min(max(limit, 1), 5000))
        }

        if lowerPath.hasSuffix(".csv") {
            if normalized.contains("summary") || normalized.contains("summarize csv") || normalized.contains("csv stats") || normalized.contains("περιληψη csv") || normalized.contains("σύνοψη csv") || normalized.contains("συνοψη csv") {
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_summary", arguments: args)
            }
            if normalized.contains("numeric stats") || normalized.contains("average") || normalized.contains("mean") || normalized.contains("median") || normalized.contains("minimum") || normalized.contains("maximum") || normalized.contains("sum") || normalized.contains("μεσο ορο") || normalized.contains("μέσο όρο") {
                guard let column = quoted.first, !column.isEmpty else { return nil }
                args["column"] = column
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_numeric_stats", arguments: args)
            }
            if normalized.contains("group by") || normalized.contains("group count") || normalized.contains("ομαδοποι") {
                guard let column = quoted.first, !column.isEmpty else { return nil }
                args["column"] = column
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_group_count", arguments: args)
            }
            if normalized.contains("select columns") || normalized.contains("keep columns") || normalized.contains("στηλες") || normalized.contains("στήλες") {
                guard !quoted.isEmpty else { return nil }
                args["columns"] = quoted.joined(separator: "|")
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_select", arguments: args)
            }
            if normalized.contains("filter csv") || normalized.contains("filter rows") || normalized.contains("φιλτραρε") || normalized.contains("φίλτραρε") {
                guard quoted.count >= 2 else { return nil }
                args["column"] = quoted[0]
                args["value"] = quoted[1]
                if normalized.contains("contains") || normalized.contains("περιεχει") || normalized.contains("περιέχει") { args["mode"] = "contains" }
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_filter", arguments: args)
            }
            if normalized.contains("csv to json") || normalized.contains("csv → json") || normalized.contains("csv σε json") {
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "csv_to_json", arguments: args)
            }
        }

        if lowerPath.hasSuffix(".json") {
            if normalized.contains("pretty json") || normalized.contains("format json") || normalized.contains("μορφοποιησε json") || normalized.contains("μορφοποίησε json") {
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "json_pretty", arguments: args)
            }
            if normalized.contains("json keys") || normalized.contains("keys του json") || normalized.contains("κλειδια json") || normalized.contains("κλειδιά json") {
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "json_keys", arguments: args)
            }
            if normalized.contains("json get") || normalized.contains("json value") || normalized.contains("τιμη json") || normalized.contains("τιμή json") {
                guard let keyPath = quoted.first, !keyPath.isEmpty else { return nil }
                args["key_path"] = keyPath
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "json_get", arguments: args)
            }
            if normalized.contains("json to csv") || normalized.contains("json → csv") || normalized.contains("json σε csv") {
                return DeterministicCapabilityInvocation(capabilityId: "local_data", operation: "json_to_csv", arguments: args)
            }
        }
        return nil
    }

    private func localArtifact(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        let markers = ["save text", "write text", "create text file", "αποθηκευσε κειμενο", "αποθήκευσε κείμενο", "γραψε αρχειο", "γράψε αρχείο"]
        guard markers.contains(where: { normalized.contains($0) }), let targetPath = paths.first else { return nil }
        let quoted = quotedValues(in: command)
        guard let text = quoted.first else { return nil }
        let target = URL(fileURLWithPath: targetPath)
        let filename = target.lastPathComponent
        guard !filename.isEmpty, !(target.pathExtension.isEmpty) else { return nil }
        return DeterministicCapabilityInvocation(
            capabilityId: "local_artifact",
            operation: "write_new",
            arguments: ["directory": target.deletingLastPathComponent().path, "filename": filename, "text": text]
        )
    }

    private func document(command: String, normalized: String, paths: [String]) -> DeterministicCapabilityInvocation? {
        guard let path = paths.first else { return nil }
        var commonArgs = ["path": path]
        if paths.count >= 2 { commonArgs["output_path"] = paths[1] }

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
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_normalized", arguments: commonArgs)
        }
        if normalized.contains("replace") || normalized.contains("αντικαταστ") {
            let quoted = quotedValues(in: command)
            guard quoted.count >= 2, !quoted[0].isEmpty else { return nil }
            commonArgs["find"] = quoted[0]
            commonArgs["replace"] = quoted[1]
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_replace", arguments: commonArgs)
        }
        if normalized.contains("sort lines") || normalized.contains("ταξινομησε τις γραμμες") || normalized.contains("ταξινόμησε τις γραμμές") {
            if normalized.contains("descending") || normalized.contains("φθινουσα") { commonArgs["descending"] = "true" }
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_sort_lines", arguments: commonArgs)
        }
        if normalized.contains("remove duplicate lines") || normalized.contains("unique lines") || normalized.contains("αφαιρεσε διπλοτυπες γραμμες") || normalized.contains("αφαίρεσε διπλότυπες γραμμές") {
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_unique_lines", arguments: commonArgs)
        }
        if normalized.contains("pretty json") || normalized.contains("format json") || normalized.contains("μορφοποιησε json") || normalized.contains("μορφοποίησε json") {
            return DeterministicCapabilityInvocation(capabilityId: "local_documents", operation: "write_pretty_json", arguments: commonArgs)
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
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) else { return nil }
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

    private func isSafeSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}
