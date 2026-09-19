import Foundation

/// Small machine-readable payload embedded inside an otherwise human-readable
/// capability result. It lets a later deterministic step consume verified
/// values from an earlier step without asking an AI model to parse prose.
enum StructuredStepOutputCodec {
    static let marker = "TRAVIS_STRUCTURED_OUTPUT_V1:"

    struct Payload: Codable, Hashable, Sendable {
        var values: [String: String]
    }

    static func append(values: [String: String], to humanText: String) -> String {
        guard let data = try? JSONEncoder().encode(Payload(values: values)) else { return humanText }
        return humanText + "\n\n" + marker + data.base64EncodedString()
    }

    static func values(from text: String) -> [String: String]? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        let token = suffix.prefix { !$0.isWhitespace }
        guard !token.isEmpty,
              let data = Data(base64Encoded: String(token)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return payload.values
    }
}
