import Foundation

/// Local, zero-token learning layer for capability routing.
/// It never stores mutation payloads or replays actions. It only learns that a
/// normalized user intent was successfully handled by a capability. Reuse is
/// conservative: at least two observations and a high lexical similarity are
/// required before this memory may bypass the LLM capability classifier.
@MainActor
final class VerifiedRoutingMemory {
    static let shared = VerifiedRoutingMemory()

    private struct Snapshot: Codable {
        var version: Int
        var entries: [Entry]
    }

    struct Entry: Codable, Hashable, Identifiable {
        let id: UUID
        var fingerprint: String
        var tokens: [String]
        var capabilityId: String
        var successCount: Int
        var lastUsedAt: Date

        init(
            id: UUID = UUID(),
            fingerprint: String,
            tokens: [String],
            capabilityId: String,
            successCount: Int = 1,
            lastUsedAt: Date = Date()
        ) {
            self.id = id
            self.fingerprint = fingerprint
            self.tokens = tokens
            self.capabilityId = capabilityId
            self.successCount = successCount
            self.lastUsedAt = lastUsedAt
        }
    }

    struct Match: Hashable {
        let capabilityId: String
        let confidence: Double
        let observations: Int
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 2_000
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("TRAVIS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("verified-routing-memory-v1.json")
        reload()
    }

    func recordSuccessfulRouting(command: String, capabilityId: String) {
        guard capabilityId != "text_task" else { return }
        let normalized = Self.normalize(command)
        let tokens = Self.meaningfulTokens(normalized)
        guard tokens.count >= 2 else { return }

        if let index = entries.firstIndex(where: {
            $0.capabilityId == capabilityId && $0.fingerprint == normalized
        }) {
            entries[index].successCount += 1
            entries[index].lastUsedAt = Date()
        } else {
            entries.append(Entry(
                fingerprint: normalized,
                tokens: tokens,
                capabilityId: capabilityId
            ))
        }

        if entries.count > maxEntries {
            entries.sort { $0.lastUsedAt > $1.lastUsedAt }
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    func bestMatch(for command: String, allowedCapabilityIds: Set<String>) -> Match? {
        let normalized = Self.normalize(command)
        let queryTokens = Set(Self.meaningfulTokens(normalized))
        guard queryTokens.count >= 2 else { return nil }

        var best: Match?

        for entry in entries where
            entry.successCount >= 2 && allowedCapabilityIds.contains(entry.capabilityId) {
            let entryTokens = Set(entry.tokens)
            let union = queryTokens.union(entryTokens)
            guard !union.isEmpty else { continue }
            let intersection = queryTokens.intersection(entryTokens)
            let similarity = Double(intersection.count) / Double(union.count)

            // Exact normalized repetitions are trusted after two successful
            // routings. Near matches require very high token-set similarity.
            let confidence = normalized == entry.fingerprint ? 1.0 : similarity
            guard confidence >= 0.84 else { continue }

            let candidate = Match(
                capabilityId: entry.capabilityId,
                confidence: confidence,
                observations: entry.successCount
            )
            if best == nil || candidate.confidence > best!.confidence ||
                (candidate.confidence == best!.confidence && candidate.observations > best!.observations) {
                best = candidate
            }
        }
        return best
    }

    func diagnosticReport() -> String {
        let reusable = entries.filter { $0.successCount >= 2 }.sorted {
            if $0.successCount != $1.successCount { return $0.successCount > $1.successCount }
            return $0.lastUsedAt > $1.lastUsedAt
        }
        let rows = reusable.prefix(30).map {
            "\($0.capabilityId) ×\($0.successCount) — \($0.fingerprint.prefix(100))"
        }.joined(separator: "\n")

        return rows.isEmpty
            ? "LOCAL ROUTING MEMORY\n\nNo reusable learned routes yet."
            : "LOCAL ROUTING MEMORY\n\n\(rows)"
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return }
        entries = snapshot.entries
    }

    private func persist() {
        let snapshot = Snapshot(version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let temp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "el_GR")
        )
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        .joined(separator: " ")
    }

    private static func meaningfulTokens(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "from", "this", "that", "στο", "στη", "στην", "στον",
            "τα", "το", "τη", "την", "των", "και", "για", "με", "μου", "σου", "θελω", "κανε",
            "κανεις", "μπορεις", "παμε", "αυτο", "αυτη", "αυτα", "ενα", "μια"
        ]
        return text.split(separator: " ").map(String.init).filter {
            $0.count >= 3 && !stopWords.contains($0)
        }
    }
}
