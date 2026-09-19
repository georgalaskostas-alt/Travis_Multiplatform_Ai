import Foundation

/// Verifies deterministic/local steps without invoking an AI model. First it
/// uses exact structural rules; when those do not apply, it can reuse strongly
/// similar verified local execution patterns learned from prior successful work.
enum DeterministicStepVerifier {
    static func verify(step: PlanStep, capabilityResult: String) -> StepVerificationResult? {
        let result = capabilityResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

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

    private static func learned(_ step: PlanStep, _ result: String) -> StepVerificationResult? {
        LearnedVerificationRegistry.shared.verify(step: step, capabilityResult: result)
    }

    private static func pass(_ reason: String) -> StepVerificationResult {
        StepVerificationResult(verdict: .pass, confidence: 1.0, reason: reason, unmetCriteria: [])
    }
}
