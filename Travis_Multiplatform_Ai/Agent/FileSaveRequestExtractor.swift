import Foundation

/// AI-based extraction of an explicit filename/location from a user's
/// free-text command — shared by every capability that can end in saving
/// a generated payload to a file (`TextTaskCapability`,
/// `SelfImprovementCapability`), so there's exactly one implementation of
/// this instead of two separately-maintained, potentially-diverging ones.
///
/// Nullable by design: only picks up what the user actually said
/// explicitly. Never invents a filename or guesses a location — callers
/// are expected to ask the user (or fall back to a sensible default)
/// when either comes back `nil`.
@MainActor
enum FileSaveRequestExtractor {
    struct Extraction {
        let filename: String?
        let location: String?
    }

    static func extract(from command: String, aiService: AIService) async throws -> Extraction {
        let prompt = """
        Ο χρήστης έγραψε: "\(command)"

        Αν ανέφερε ρητά συγκεκριμένο όνομα αρχείου (π.χ. "αποθήκευσέ το με όνομα Χ", "δώσε όνομα Χ"), βάλε αυτό το όνομα στο πεδίο "filename" (χωρίς κατάληξη .txt). Αν δεν ανέφερε όνομα, το "filename" πρέπει να είναι null — ΜΗΝ επινοήσεις όνομα μόνος σου.

        Αν ανέφερε ρητά μια τοποθεσία αποθήκευσης (π.χ. "στο desktop", "στα Documents", ή ένα συγκεκριμένο path), βάλε αυτή την τοποθεσία στο πεδίο "location" ακριβώς όπως την περιέγραψε. Αν δεν ανέφερε τοποθεσία, το "location" πρέπει να είναι null — ΜΗΝ υποθέσεις τοποθεσία μόνος σου.

        Απάντησε ΑΠΟΚΛΕΙΣΤΙΚΑ με ένα JSON object, χωρίς κανένα άλλο κείμενο πριν ή μετά, ακριβώς σε αυτή τη μορφή:
        {"filename": "το όνομα αρχείου ή null", "location": "η τοποθεσία αποθήκευσης ή null"}
        """

        let raw = try await aiService.generateText(prompt: prompt)
        return parse(raw)
    }

    /// Trims, strips path separators, and appends `.txt` if missing —
    /// applied uniformly whether the name came from the user's own words
    /// or a caller's auto-generated fallback, so every saved file ends up
    /// consistently named regardless of which path produced it.
    static func sanitizeFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: CharacterSet(charactersIn: "/\\")).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            name = "travis-text-\(Int(Date().timeIntervalSince1970))"
        }

        if !name.lowercased().hasSuffix(".txt") {
            name += ".txt"
        }

        return name
    }

    private static func parse(_ text: String) -> Extraction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jsonStart = trimmed.firstIndex(of: "{"),
            let jsonEnd = trimmed.lastIndex(of: "}"),
            jsonStart < jsonEnd,
            let data = trimmed[jsonStart...jsonEnd].data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Extraction(filename: nil, location: nil)
        }

        return Extraction(filename: object["filename"] as? String, location: object["location"] as? String)
    }
}
