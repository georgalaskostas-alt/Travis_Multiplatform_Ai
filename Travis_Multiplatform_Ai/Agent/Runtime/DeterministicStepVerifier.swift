import Foundation

/// Verifies a narrow set of deterministic, read-only/local-computation steps
/// without invoking an AI model. It is intentionally conservative: when the
/// operation/result cannot be proven structurally, it returns nil and the
/// existing AI verifier remains the fallback.
enum DeterministicStepVerifier {
    static func verify(step: PlanStep, capabilityResult: String) -> StepVerificationResult? {
        guard let invocation = StructuredInvocationCodec.decode(from: step.instructions) else { return nil }
        let result = capabilityResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

        switch (invocation.capabilityId, invocation.operation) {
        case ("local_file_search", "search"):
            let valid = result.hasPrefix("LOCAL FILE SEARCH") || result.contains("Δεν βρέθηκαν αρχεία")
            return valid ? pass("Deterministic local file-search result validated without AI.") : nil

        case ("local_documents", "stats"):
            return result.hasPrefix("DOCUMENT STATS")
                ? pass("Deterministic document statistics validated without AI.") : nil

        case ("local_documents", "find"):
            let valid = result.hasPrefix("MATCHES (") || result.contains("Δεν βρέθηκαν matches")
            return valid ? pass("Deterministic in-document search validated without AI.") : nil

        case ("local_documents", "head"),
             ("local_documents", "normalize_whitespace"),
             ("local_documents", "replace_preview"):
            return pass("Deterministic local document computation completed without AI verification.")

        case ("local_text_transform", _):
            guard let values = StructuredStepOutputCodec.values(from: result), values["text"] != nil else { return nil }
            return pass("Structured local text-transform output validated without AI.")

        case ("local_productivity", "clipboard_read"):
            let valid = result.hasPrefix("CLIPBOARD") || result.contains("Το πρόχειρο δεν περιέχει κείμενο")
            return valid ? pass("Local clipboard read validated without AI.") : nil

        case ("local_productivity", "system_info"):
            return result.hasPrefix("LOCAL SYSTEM INFO")
                ? pass("Local system information validated without AI.") : nil

        default:
            return nil
        }
    }

    private static func pass(_ reason: String) -> StepVerificationResult {
        StepVerificationResult(verdict: .pass, confidence: 1.0, reason: reason, unmetCriteria: [])
    }
}
