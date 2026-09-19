import Foundation
#if os(macOS)
import Network
#endif

final class TravisFCCBridgeServer {
    static let shared = TravisFCCBridgeServer()

    private(set) var isRunning = false
    private(set) var lastError: String?

    #if os(macOS)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "travis.fcc.bridge")
    #endif

    private init() {}

    func start() {
        #if os(macOS)
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: 8765)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.isRunning = true; self.lastError = nil
                case .failed(let error): self.isRunning = false; self.lastError = error.localizedDescription
                case .cancelled: self.isRunning = false
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        listener?.cancel(); listener = nil
        #endif
        isRunning = false
    }

    #if os(macOS)
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            if self.requestIsComplete(next) || isComplete || error != nil {
                Task {
                    let response = await self.handle(rawRequest: next)
                    self.send(response, on: connection)
                }
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func requestIsComplete(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let headerRange = text.range(of: "\r\n\r\n") else { return false }
        let headers = String(text[..<headerRange.lowerBound])
        let contentLength = headers.split(separator: "\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") } ?? 0
        return text[headerRange.upperBound...].utf8.count >= contentLength
    }

    private func handle(rawRequest data: Data) async -> HTTPResponse {
        guard let text = String(data: data, encoding: .utf8), let headerRange = text.range(of: "\r\n\r\n") else {
            return .json(status: 400, object: ["error": "invalid request"])
        }
        let firstLine = text[..<headerRange.lowerBound].split(separator: "\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .json(status: 400, object: ["error": "invalid request line"]) }
        let method = String(parts[0]).uppercased(), path = String(parts[1])

        if method == "GET" && path == "/v1/fcc/status" {
            return .json(status: 200, object: ["status":"ok","service":"TRAVIS","bridge":"fcc","model":"TRAVIS-router","read_only":true,"local_link":true])
        }

        if method == "POST" && path == "/v1/fcc/analyze" {
            let bodyText = String(text[headerRange.upperBound...])
            guard let bodyData = bodyText.data(using: .utf8), let payload = try? JSONDecoder().decode(FCCRequest.self, from: bodyData), !payload.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .json(status: 422, object: ["error":"invalid FCC analysis request"])
            }

            let foundationEvidence = payload.evidence.mapValues { $0.foundation }
            let evidenceData = try? JSONSerialization.data(withJSONObject: foundationEvidence, options: [.prettyPrinted, .sortedKeys])
            let evidenceText = evidenceData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let prompt = """
            FCC READ-ONLY ANALYSIS REQUEST

            SAFETY RULES:
            - Use only the supplied process evidence.
            - Never invent tag values, alarms, limits, events or operating facts.
            - Separate observed facts from engineering hypotheses.
            - Do not issue plant write commands or setpoint changes.

            QUESTION:
            \(payload.question)

            PROCESS EVIDENCE:
            \(evidenceText)
            """
            do {
                let answer = try await AIExecutionScope.$context.withValue(
                    AIInvocationContext(workload: .complex, capabilityId: "fcc_assistant", operation: "fcc.bridge.analysis")
                ) { try await AIService.shared.generateText(prompt: prompt, maxTokens: 1800) }
                return .json(status: 200, object: ["answer":answer,"provider":"TRAVIS","read_only":true])
            } catch {
                return .json(status: 503, object: ["error":error.localizedDescription])
            }
        }

        return .json(status: 404, object: ["error":"not found"])
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct FCCRequest: Decodable {
        let source: String?
        let mode: String?
        let question: String
        let systemPrompt: String?
        let evidence: [String: JSONValue]
        enum CodingKeys: String, CodingKey { case source, mode, question, evidence; case systemPrompt = "system_prompt" }
    }

    private enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
        }
        var foundation: Any {
            switch self { case .string(let v): return v; case .number(let v): return v; case .bool(let v): return v; case .object(let v): return v.mapValues(\.foundation); case .array(let v): return v.map(\.foundation); case .null: return NSNull() }
        }
    }

    private struct HTTPResponse {
        let data: Data
        static func json(status: Int, object: [String: Any]) -> HTTPResponse {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            let reason: String
            switch status { case 200: reason="OK"; case 400: reason="Bad Request"; case 404: reason="Not Found"; case 422: reason="Unprocessable Entity"; default: reason="Service Unavailable" }
            let header="HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var data=Data(header.utf8); data.append(body); return HTTPResponse(data:data)
        }
    }
    #endif
}
