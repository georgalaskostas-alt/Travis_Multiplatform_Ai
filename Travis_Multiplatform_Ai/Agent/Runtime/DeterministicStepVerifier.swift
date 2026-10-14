import Foundation

/// Verifies deterministic/local steps without invoking an AI model. First it
/// uses exact structural rules; when those do not apply, it can reuse strongly
/// similar verified local execution patterns learned from prior successful work.
enum DeterministicStepVerifier {
    static func verify(step: PlanStep, capabilityResult: String) -> StepVerificationResult? {
        let result = capabilityResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

        // Runtime diagnostics may be planned with plain-language instructions.
        // Route by the assigned capability rather than requiring an encoded invocation.
        if step.capabilityId == "runtime_health" {
            return verifyRuntimeHealth(result)
        }

        guard let invocation = StructuredInvocationCodec.decode(from: step.instructions) else {
            return LearnedVerificationRegistry.shared.verify(step: step, capabilityResult: result)
        }

        switch (invocation.capabilityId, invocation.operation) {
        case ("local_file_search", "search"):
            let valid = result.hasPrefix("LOCAL FILE SEARCH") || result.contains("Δεν βρέθηκαν αρχεία")
            return valid ? pass("Deterministic local file-search result validated without AI.") : learned(step, result)

        case ("local_directory_analysis", "inventory"):
            return result.hasPrefix("LOCAL DIRECTORY INVENTORY") ? pass("Local directory inventory validated without AI.") : learned(step, result)
        case ("local_directory_analysis", "extension_summary"):
            return result.hasPrefix("LOCAL DIRECTORY EXTENSION SUMMARY") ? pass("Local extension summary validated without AI.") : learned(step, result)
        case ("local_directory_analysis", "largest_files"):
            return result.hasPrefix("LOCAL DIRECTORY LARGEST FILES") ? pass("Local largest-file report validated without AI.") : learned(step, result)
        case ("local_directory_analysis", "duplicates"):
            return result.hasPrefix("LOCAL DIRECTORY DUPLICATES") ? pass("Local duplicate-file analysis validated without AI.") : learned(step, result)

        case ("local_documents", "stats"):
            return result.hasPrefix("DOCUMENT STATS") ? pass("Deterministic document statistics validated without AI.") : learned(step, result)

        case ("local_documents", "find"):
            let valid = result.hasPrefix("MATCHES (") || result.contains("Δεν βρέθηκαν matches")
            return valid ? pass("Deterministic in-document search validated without AI.") : learned(step, result)

        case ("local_documents", "head"),
             ("local_documents", "normalize_whitespace"),
             ("local_documents", "replace_preview"):
            return pass("Deterministic local document computation completed without AI verification.")

        case ("local_text_transform", _):
            guard let values = StructuredStepOutputCodec.values(from: result), values["text"] != nil else {
                return learned(step, result)
            }
            return pass("Structured local text-transform output validated without AI.")

        case ("local_data", "csv_summary"):
            return result.hasPrefix("LOCAL DATA CSV SUMMARY") ? pass("Local CSV summary validated without AI.") : learned(step, result)
        case ("local_data", "csv_select"):
            return result.hasPrefix("LOCAL DATA CSV SELECT") ? pass("Local CSV projection validated without AI.") : learned(step, result)
        case ("local_data", "csv_filter"):
            return result.hasPrefix("LOCAL DATA CSV FILTER") ? pass("Local CSV filter validated without AI.") : learned(step, result)
        case ("local_data", "csv_numeric_stats"):
            return result.hasPrefix("LOCAL DATA CSV NUMERIC STATS") ? pass("Local CSV numeric statistics validated without AI.") : learned(step, result)
        case ("local_data", "csv_group_count"):
            return result.hasPrefix("LOCAL DATA CSV GROUP COUNT") ? pass("Local CSV grouping validated without AI.") : learned(step, result)
        case ("local_data", "csv_to_json"):
            return result.hasPrefix("LOCAL DATA JSON") ? pass("Local CSV to JSON conversion validated without AI.") : learned(step, result)
        case ("local_data", "json_pretty"):
            return result.hasPrefix("LOCAL DATA JSON PRETTY") ? pass("Local JSON formatting validated without AI.") : learned(step, result)
        case ("local_data", "json_keys"):
            return result.hasPrefix("LOCAL DATA JSON KEYS") ? pass("Local JSON key inspection validated without AI.") : learned(step, result)
        case ("local_data", "json_get"):
            return result.hasPrefix("LOCAL DATA JSON VALUE") ? pass("Local JSON value lookup validated without AI.") : learned(step, result)
        case ("local_data", "json_to_csv"):
            return result.hasPrefix("LOCAL DATA CSV") ? pass("Local JSON to CSV conversion validated without AI.") : learned(step, result)

        case ("local_productivity", "clipboard_read"):
            let valid = result.hasPrefix("CLIPBOARD") || result.contains("Το πρόχειρο δεν περιέχει κείμενο")
            return valid ? pass("Local clipboard read validated without AI.") : learned(step, result)

        case ("local_productivity", "system_info"):
            return result.hasPrefix("LOCAL SYSTEM INFO") ? pass("Local system information validated without AI.") : learned(step, result)

        default:
            return learned(step, result)
        }
    }

    private static func verifyRuntimeHealth(_ result: String) -> StepVerificationResult {
        let lines = result.components(separatedBy: .newlines)
        guard lines.first == "TRAVIS RUNTIME HEALTH" else {
            return healthFailure("Missing runtime health report header.")
        }

        var fields: [String: String] = [:]
        let required: Set<String> = [
            "process", "processorCount", "activeProcessorCount",
            "physicalMemoryBytes", "osVersion", "collectedAt"
        ]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard required.contains(key) else { continue }
            guard fields[key] == nil else {
                return healthFailure("Duplicate health field: \\(key).")
            }
            fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        guard required.allSatisfy({ !(fields[$0] ?? "").isEmpty }),
              fields["process"] == "active",
              let processors = Int(fields["processorCount"] ?? ""), processors > 0,
              let active = Int(fields["activeProcessorCount"] ?? ""), active > 0, active <= processors,
              let memory = UInt64(fields["physicalMemoryBytes"] ?? ""), memory > 0,
              let timestamp = fields["collectedAt"],
              ISO8601DateFormatter().date(from: timestamp) != nil
        else {
            return healthFailure("Missing or inconsistent runtime health evidence.")
        }

        return pass("Validated local process health evidence without AI; remote worker health is not asserted.")
    }

    private static func healthFailure(_ reason: String) -> StepVerificationResult {
        StepVerificationResult(verdict: .insufficientEvidence, confidence: 1.0,
                               reason: reason, unmetCriteria: [reason])
    }

    private static func learned(_ step: PlanStep, _ result: String) -> StepVerificationResult? {
        LearnedVerificationRegistry.shared.verify(step: step, capabilityResult: result)
    }

    private static func pass(_ reason: String) -> StepVerificationResult {
        StepVerificationResult(verdict: .pass, confidence: 1.0, reason: reason, unmetCriteria: [])
    }
}
