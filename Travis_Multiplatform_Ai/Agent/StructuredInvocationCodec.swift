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
              let invocation = try? JSONDecoder().decode(DeterministicCapabilityInvocation.self, from: data) else {
            return nil
        }
        return invocation
    }
}
