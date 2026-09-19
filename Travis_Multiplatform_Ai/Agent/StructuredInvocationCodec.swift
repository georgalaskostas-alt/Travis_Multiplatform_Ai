import Foundation

enum StructuredInvocationCodec {
    static let marker = "TRAVIS_STRUCTURED_INVOCATION_V1:"

    static func encode(_ invocation: DeterministicCapabilityInvocation) throws -> String {
        let data = try JSONEncoder().encode(invocation)
        return marker + data.base64EncodedString()
    }

    static func decode(from text: String) -> DeterministicCapabilityInvocation? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        let token = suffix.prefix { !$0.isWhitespace }
        guard !token.isEmpty,
              let data = Data(base64Encoded: String(token)),
              let decoded = try? JSONDecoder().decode(DeterministicCapabilityInvocation.self, from: data) else {
            return nil
        }

        return resolveVerifiedDependencyArguments(for: decoded, from: text)
    }

    /// Local autonomous execution embeds verified dependency results in the
    /// execution command. For filesystem mutations we can safely replace a
    /// broad extension selector with the exact filenames returned by the
    /// completed local_file_search step. No AI interpretation is involved.
    private static func resolveVerifiedDependencyArguments(
        for invocation: DeterministicCapabilityInvocation,
        from text: String
    ) -> DeterministicCapabilityInvocation {
        guard invocation.capabilityId == "advanced_filesystem",
              ["copy", "move", "delete", "organize_extension"].contains(invocation.operation),
              invocation.arguments["names"]?.isEmpty != false else {
            return invocation
        }

        let names = verifiedLocalSearchNames(in: text)
        guard !names.isEmpty else { return invocation }

        var arguments = invocation.arguments
        arguments["names"] = names.joined(separator: "|")
        arguments.removeValue(forKey: "matchExtension")

        return DeterministicCapabilityInvocation(
            capabilityId: invocation.capabilityId,
            operation: invocation.operation,
            arguments: arguments
        )
    }

    private static func verifiedLocalSearchNames(in text: String) -> [String] {
        guard text.contains("VERIFIED DEPENDENCY EVIDENCE:"),
              text.contains("LOCAL FILE SEARCH") else { return [] }

        var seen = Set<String>()
        var names: [String] = []

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard line.hasPrefix("FILE |") else { continue }
            let fields = line.components(separatedBy: " | ")
            guard fields.count >= 4 else { continue }
            let relative = fields.dropFirst(3).joined(separator: " | ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Current deterministic transfer/delete workflows are deliberately
            // non-recursive, so only simple filenames are accepted here.
            guard !relative.isEmpty,
                  relative != ".",
                  relative != "..",
                  !relative.contains("/"),
                  !relative.contains("\\"),
                  !relative.contains("|") else { continue }

            if seen.insert(relative).inserted {
                names.append(relative)
            }
        }

        return names
    }
}
