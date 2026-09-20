import Foundation
import Observation

@MainActor
@Observable
final class TravisCloudControlPlane {
    static let shared = TravisCloudControlPlane()
    enum LinkState:String,Codable { case disabled,connecting,online,degraded,unauthorized }
    struct Device:Codable,Identifiable,Equatable { let id:UUID;let device_key:String;let display_name:String;let platform:String;var worker_online:Bool;var gui_online:Bool;var lan_online:Bool;var cloud_online:Bool;var kill_switch:Bool;var last_seen_at:Date? }
    struct Command:Codable,Identifiable,Equatable { let id:UUID;let target_device_id:UUID;let command_type:String;let payload:[String:String]?;let nonce:UUID;let status:String;let created_at:Date?;let expires_at:Date?;let result:[String:String]? }
    private let base=URL(string:"https://ggppmrcsdjhbasubhzit.supabase.co")!
    private let publishableKey="sb_publishable_M7xNRugheKl_cIRzULxrrw_v0qoxyEc"
    private(set) var state:LinkState = .disabled
    private(set) var lastError:String?;private(set) var lastSyncAt:Date?;private(set) var deviceID:UUID?
    private var loop:Task<Void,Never>?;private var accessToken:String?

    /// Pass the signed-in user's Supabase JWT from the app session/Keychain. This service never persists it.
    func configure(accessToken:String?){self.accessToken=accessToken?.trimmingCharacters(in:.whitespacesAndNewlines);if self.accessToken?.isEmpty==true{self.accessToken=nil};state=self.accessToken==nil ? .unauthorized:.connecting}
    func startMacHeartbeat(deviceKey:String,displayName:String,workerOnline:@escaping @MainActor()->Bool,guiOnline:@escaping @MainActor()->Bool,lanOnline:@escaping @MainActor()->Bool){
        loop?.cancel();guard accessToken != nil else{state = .unauthorized;return}
        loop=Task{[weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    // Keep the long-running control-plane loop on a renewable
                    // Supabase session. Refresh happens before expiry and the
                    // rotated access token is adopted before any REST request.
                    let token = try await TravisCloudAuthService.shared.validAccessToken()
                    self.accessToken = token

                    #if os(macOS)
                    AlwaysOnWorkerMonitor.shared.refresh()
                    let workerSnapshot = AlwaysOnWorkerMonitor.shared.snapshot
                    #else
                    let workerSnapshot: AlwaysOnWorkerMonitor.Snapshot? = nil
                    #endif

                    let id: UUID
                    if let workerSnapshot {
                        id = try await self.upsertDevice(
                            deviceKey: deviceKey,
                            displayName: displayName,
                            platform: "macos",
                            worker: workerOnline(),
                            gui: guiOnline(),
                            lan: lanOnline(),
                            killSwitch: workerSnapshot.killSwitch
                        )
                        self.deviceID = id
                    } else {
                        let knownID: UUID?
                        if let cachedID = self.deviceID {
                            knownID = cachedID
                        } else {
                            knownID = try await self.existingDeviceID(deviceKey: deviceKey)
                        }

                        guard let knownID else {
                            throw CloudError.workerTelemetryUnavailable
                        }

                        // Never invent kill-switch telemetry. Still keep the
                        // command channel alive so a remote safety command can
                        // reach the Mac while worker telemetry is unavailable.
                        id = knownID
                        self.deviceID = knownID
                    }

                    try await self.processCommands(for: id)

                    if workerSnapshot == nil {
                        self.state = .degraded
                        self.lastError = CloudError.workerTelemetryUnavailable.localizedDescription
                    } else {
                        self.state = .online
                        self.lastError = nil
                        self.lastSyncAt = Date()
                    }
                } catch {
                    self.state = .degraded
                    self.lastError = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func stop(){loop?.cancel();loop=nil;state = .disabled}

    private func existingDeviceID(deviceKey:String) async throws -> UUID? {
        struct Row: Decodable { let id: UUID }
        guard let encoded = deviceKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw CloudError.invalidResponse
        }
        let data = try await request(
            path: "/rest/v1/travis_devices?device_key=eq.\(encoded)&select=id&limit=2",
            method: "GET"
        )
        let rows = try decoder.decode([Row].self, from: data)
        guard rows.count <= 1 else { throw CloudError.invalidResponse }
        return rows.first?.id
    }

    private func upsertDevice(deviceKey:String,displayName:String,platform:String,worker:Bool,gui:Bool,lan:Bool,killSwitch:Bool) async throws -> UUID{
        struct Body:Encodable{let device_key:String;let display_name:String;let platform:String;let worker_online:Bool;let gui_online:Bool;let lan_online:Bool;let cloud_online:Bool;let kill_switch:Bool;let last_seen_at:String}
        let b=Body(device_key:deviceKey,display_name:displayName,platform:platform,worker_online:worker,gui_online:gui,lan_online:lan,cloud_online:true,kill_switch:killSwitch,last_seen_at:ISO8601DateFormatter().string(from:Date()))
        let data=try await request(path:"/rest/v1/travis_devices?on_conflict=user_id,device_key",method:"POST",body:b,prefer:"resolution=merge-duplicates,return=representation");let values=try decoder.decode([Device].self,from:data);guard let id=values.first?.id else{throw CloudError.invalidResponse};return id
    }
    private func processCommands(for id: UUID) async throws {
        let now = ISO8601DateFormatter()
            .string(from: Date())
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        let data = try await request(
            path: "/rest/v1/travis_commands?target_device_id=eq.\(id.uuidString)&status=eq.queued&expires_at=gt.\(now)&order=created_at.asc&limit=20",
            method: "GET"
        )

        let commands = try decoder.decode([Command].self, from: data)

        for command in commands {
            guard let claimed = try await claimCommandAtomically(
                commandID: command.id,
                targetDeviceID: id
            ) else {
                // Another consumer already claimed it, it expired, or it
                // is no longer queued. This process must not execute it.
                continue
            }

            try await processCommand(claimed)
        }
    }

    private func claimCommandAtomically(
        commandID: UUID,
        targetDeviceID: UUID
    ) async throws -> Command? {
        struct Body: Encodable {
            let p_command_id: UUID
            let p_target_device_id: UUID
        }

        let body = Body(
            p_command_id: commandID,
            p_target_device_id: targetDeviceID
        )

        let data = try await request(
            path: "/rest/v1/rpc/travis_claim_command",
            method: "POST",
            body: body
        )

        let claimed = try decoder.decode([Command].self, from: data)

        guard claimed.count <= 1 else {
            throw CloudError.invalidResponse
        }

        return claimed.first
    }

    private func processCommand(_ command: Command) async throws {
        let receipts = TravisControlCommandReceiptStore.shared

        let normalized: Command
        do {
            normalized = try normalizeCommand(command)
        } catch {
            try await patchCommand(
                command.id,
                status: "failed",
                result: "Invalid control command semantics: \(error.localizedDescription)"
            )
            return
        }

        let payload = normalized.payload ?? [:]

        let claim: TravisControlCommandReceiptStore.Claim

        do {
            claim = try await receipts.claim(
                commandID: normalized.id,
                nonce: normalized.nonce,
                commandType: normalized.command_type,
                sourceDeviceID: normalized.target_device_id,
                payload: payload
            )
        } catch {
            // Fail closed: no durable claim means no side effect.
            try await patchCommand(
                command.id,
                status: "failed",
                result: "Control Plane receipt persistence failed; execution blocked: \(error.localizedDescription)"
            )
            return
        }

        switch claim {
        case .conflict:
            try await patchCommand(
                command.id,
                status: "failed",
                result: "Control command identity conflict; execution blocked."
            )
            return

        case .duplicate(let receipt):
            if let resultStatus = receipt.resultStatus,
               let resultMessage = receipt.resultMessage {

                let cloudStatus: String

                switch resultStatus {
                case .completed:
                    cloudStatus = "completed"

                case .failed, .expired,
                     .queued, .acknowledged, .executing:
                    cloudStatus = "failed"
                }

                try await patchCommand(
                    command.id,
                    status: cloudStatus,
                    result: resultMessage
                )
            } else {
                // Never turn an unresolved duplicate into a terminal failure.
                // The original LAN/Cloud invocation may still be executing.
                // Keep the server command acknowledged so clients know that
                // Mac owns it, while preventing any second side effect.
                try await patchCommand(
                    command.id,
                    status: "acknowledged",
                    result: "Duplicate command suppressed: original execution is still unresolved."
                )
            }

            return

        case .execute:
            break
        }

        // Server-side atomic claim already transitioned this command
        // from queued to acknowledged. Reaching this point means this
        // consumer owns execution of this cloud delivery.
        let output = await execute(normalized)

        let terminalStatus: TravisControlCommandStatus =
            output.ok ? .completed : .failed

        do {
            try await receipts.finish(
                commandID: command.id,
                status: terminalStatus,
                message: output.message
            )
        } catch {
            // The side effect may already have happened. Do not make this
            // command eligible for automatic execution again.
            try await patchCommand(
                command.id,
                status: "failed",
                result: "Command may have executed, but terminal receipt persistence failed; reconciliation required: \(error.localizedDescription)"
            )
            return
        }

        try await patchCommand(
            command.id,
            status: output.ok ? "completed" : "failed",
            result: output.message
        )
    }

    private func normalizeCommand(_ command: Command) throws -> Command {
        let rawType = command.command_type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var payload = command.payload ?? [:]

        switch rawType {
        case "kill_switch.enable":
            payload["enabled"] = "true"

            return Command(
                id: command.id,
                target_device_id: command.target_device_id,
                command_type: "killSwitch",
                payload: payload,
                nonce: command.nonce,
                status: command.status,
                created_at: command.created_at,
                expires_at: command.expires_at,
                result: command.result
            )

        case "kill_switch.disable":
            payload["enabled"] = "false"

            return Command(
                id: command.id,
                target_device_id: command.target_device_id,
                command_type: "killSwitch",
                payload: payload,
                nonce: command.nonce,
                status: command.status,
                created_at: command.created_at,
                expires_at: command.expires_at
            )

        case "killswitch", "kill_switch":
            guard let rawEnabled = payload["enabled"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  rawEnabled == "true" || rawEnabled == "false" else {
                throw CloudError.invalidCommand(
                    "killSwitch requires payload.enabled=true or false"
                )
            }

            payload["enabled"] = rawEnabled

            return Command(
                id: command.id,
                target_device_id: command.target_device_id,
                command_type: "killSwitch",
                payload: payload,
                nonce: command.nonce,
                status: command.status,
                created_at: command.created_at,
                expires_at: command.expires_at
            )

        default:
            return command
        }
    }

    private func execute(_ c: Command) async -> (ok: Bool, message: String) {
        switch c.command_type.lowercased() {
        case "killswitch":
            guard let rawEnabled = c.payload?["enabled"]?.lowercased(),
                  rawEnabled == "true" || rawEnabled == "false" else {
                return (false, "Malformed kill switch command")
            }

            let enabled = rawEnabled == "true"

            // Use the same canonical safety handler as LAN/local commands.
            // Enabling the kill switch stops the headless worker AND pauses
            // enabled GUI-runtime jobs. Clearing only releases the kill switch;
            // paused jobs are deliberately not resumed automatically.
            let coordinator = AlwaysOnRuntimeCoordinator.shared
            if enabled {
                coordinator.emergencyStop()
            } else {
                coordinator.clearEmergencyStop()
            }
            if let error = coordinator.lastError {
                return (false, error)
            }

            // The control file is written synchronously, but the independent
            // worker updates its heartbeat asynchronously. Give it a short,
            // bounded window to confirm the requested state instead of
            // falsely failing an otherwise accepted safety command.
            let deadline = Date().addingTimeInterval(2.5)
            repeat {
                coordinator.worker.refresh()
                if coordinator.worker.snapshot?.killSwitch == enabled {
                    return (
                        true,
                        enabled ? "Kill switch enabled" : "Kill switch cleared"
                    )
                }
                if Date() >= deadline { break }
                try? await Task.sleep(for: .milliseconds(150))
            } while !Task.isCancelled

            return (false, "Kill switch command was accepted but worker confirmation timed out")

        case "worker_job":
            guard let action = c.payload?["action"],
                  let raw = c.payload?["job_id"],
                  let id = UUID(uuidString: raw) else {
                return (false, "Malformed worker job command")
            }

            do {
                try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(
                    action: action,
                    jobID: id
                )
                return (true, "Worker command queued")
            } catch {
                return (false, error.localizedDescription)
            }

        default:
            return (false, "Command type is not allowlisted")
        }
    }

    private func patchCommand(_ id:UUID,status:String,result:String?) async throws{struct Patch:Encodable{let status:String;let acknowledged_at:String?;let completed_at:String?;let result:[String:String]?};let now=ISO8601DateFormatter().string(from:Date());let terminal=["completed","failed"].contains(status);let p=Patch(status:status,acknowledged_at:status=="acknowledged" ? now:nil,completed_at:terminal ? now:nil,result:result.map{["message":$0]});_ = try await request(path:"/rest/v1/travis_commands?id=eq.\(id.uuidString)",method:"PATCH",body:p)}
    @discardableResult
    func sendCommand(
        targetDeviceID: UUID,
        type: String,
        payload: [String: String] = [:],
        commandID: UUID = UUID(),
        nonce: UUID = UUID(),
        expiresAt: Date = Date().addingTimeInterval(300)
    ) async throws -> (commandID: UUID, nonce: UUID) {
        struct Body: Encodable {
            let id: UUID
            let target_device_id: UUID
            let command_type: String
            let payload: [String: String]
            let nonce: UUID
            let expires_at: String
        }

        let body = Body(
            id: commandID,
            target_device_id: targetDeviceID,
            command_type: type,
            payload: payload,
            nonce: nonce,
            expires_at: ISO8601DateFormatter().string(from: expiresAt)
        )

        _ = try await request(
            path: "/rest/v1/travis_commands",
            method: "POST",
            body: body
        )

        return (commandID, nonce)
    }

    @discardableResult
    func sendCommand(
        _ command: TravisControlCommand,
        targetDeviceID: UUID
    ) async throws -> (commandID: UUID, nonce: UUID) {
        try await sendCommand(
            targetDeviceID: targetDeviceID,
            type: command.type.rawValue,
            payload: command.payload,
            commandID: command.id,
            nonce: command.nonce,
            expiresAt: command.expiresAt
        )
    }
    func commandStatus(commandID:UUID) async throws -> Command? {
        let data=try await request(path:"/rest/v1/travis_commands?id=eq.\(commandID.uuidString)&select=*",method:"GET")
        let values=try decoder.decode([Command].self,from:data)
        guard values.count <= 1 else{throw CloudError.invalidResponse}
        return values.first
    }
    func devices() async throws->[Device]{let data=try await request(path:"/rest/v1/travis_devices?select=*&order=last_seen_at.desc",method:"GET");return try decoder.decode([Device].self,from:data)}

    private var decoder:JSONDecoder{let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return d}
    private func preparedRequest(path:String,method:String,prefer:String?) throws -> URLRequest{guard let token=accessToken,!token.isEmpty else{state = .unauthorized;throw CloudError.unauthorized};guard let url=URL(string:path,relativeTo:base) else{throw CloudError.invalidResponse};var r=URLRequest(url:url);r.httpMethod=method;r.setValue(publishableKey,forHTTPHeaderField:"apikey");r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");if let prefer{r.setValue(prefer,forHTTPHeaderField:"Prefer")};return r}
    private func perform(_ r:URLRequest) async throws -> Data{let(data,response)=try await URLSession.shared.data(for:r);guard let h=response as? HTTPURLResponse else{throw CloudError.invalidResponse};guard 200..<300 ~= h.statusCode else{throw CloudError.http(h.statusCode,String(data:data,encoding:.utf8) ?? "")};return data}

    /// Executes an authenticated Control Plane request. A JWT can expire or be
    /// revoked between the proactive heartbeat refresh and the actual REST
    /// request, so a 401 gets exactly one forced refresh + retry. Never retry
    /// other HTTP failures automatically: command POSTs must not be duplicated.
    private func authenticatedRequest(_ makeRequest:(String)throws->URLRequest) async throws -> Data {
        let token = try await TravisCloudAuthService.shared.validAccessToken()
        self.accessToken = token
        do {
            return try await perform(makeRequest(token))
        } catch CloudError.http(let status, _) where status == 401 {
            let refreshed = try await TravisCloudAuthService.shared.refreshSession()
            self.accessToken = refreshed.accessToken
            return try await perform(makeRequest(refreshed.accessToken))
        }
    }

    private func request(path:String,method:String,prefer:String?=nil) async throws -> Data{
        try await authenticatedRequest { token in
            self.accessToken = token
            return try self.preparedRequest(path:path,method:method,prefer:prefer)
        }
    }
    private func request<B:Encodable>(path:String,method:String,body:B,prefer:String?=nil) async throws -> Data{
        let encodedBody = try JSONEncoder().encode(body)
        return try await authenticatedRequest { token in
            self.accessToken = token
            var r=try self.preparedRequest(path:path,method:method,prefer:prefer)
            r.httpBody=encodedBody
            return r
        }
    }
    enum CloudError: LocalizedError {
        case unauthorized
        case invalidResponse
        case invalidCommand(String)
        case workerTelemetryUnavailable
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Cloud authentication required"
            case .invalidResponse:
                return "Invalid cloud response"
            case .invalidCommand(let message):
                return message
            case .workerTelemetryUnavailable:
                return "Always-On worker telemetry unavailable; cloud state was not updated."
            case let .http(code, msg):
                return "Cloud HTTP \(code): \(msg)"
            }
        }
    }
}
