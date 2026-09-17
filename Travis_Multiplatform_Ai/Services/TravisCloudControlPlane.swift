import Foundation
import Observation

@MainActor
@Observable
final class TravisCloudControlPlane {
    static let shared = TravisCloudControlPlane()
    enum LinkState:String,Codable { case disabled,connecting,online,degraded,unauthorized }
    struct Device:Codable,Identifiable,Equatable { let id:UUID;let device_key:String;let display_name:String;let platform:String;var worker_online:Bool;var gui_online:Bool;var lan_online:Bool;var cloud_online:Bool;var kill_switch:Bool;var last_seen_at:Date? }
    struct Command:Codable,Identifiable,Equatable { let id:UUID;let target_device_id:UUID;let command_type:String;let payload:[String:String]?;let nonce:UUID;let status:String;let created_at:Date?;let expires_at:Date? }
    private let base=URL(string:"https://ggppmrcsdjhbasubhzit.supabase.co")!
    private let publishableKey="sb_publishable_gjOzx9KtM5eKTy62_NkZ8Q_41ZMP2-I"
    private(set) var state:LinkState = .disabled
    private(set) var lastError:String?;private(set) var lastSyncAt:Date?;private(set) var deviceID:UUID?
    private var loop:Task<Void,Never>?;private var accessToken:String?

    /// Pass the signed-in user's Supabase JWT from the app session/Keychain. This service never persists it.
    func configure(accessToken:String?){self.accessToken=accessToken;state=accessToken==nil ? .unauthorized:.connecting}
    func startMacHeartbeat(deviceKey:String,displayName:String,workerOnline:@escaping @MainActor()->Bool,guiOnline:@escaping @MainActor()->Bool,lanOnline:@escaping @MainActor()->Bool){
        loop?.cancel();guard accessToken != nil else{state = .unauthorized;return}
        loop=Task{[weak self] in while !Task.isCancelled{guard let self else{return};do{let id=try await self.upsertDevice(deviceKey:deviceKey,displayName:displayName,platform:"macos",worker:workerOnline(),gui:guiOnline(),lan:lanOnline());self.deviceID=id;try await self.processCommands(for:id);self.state = .online;self.lastError=nil;self.lastSyncAt=Date()}catch{self.state = .degraded;self.lastError=error.localizedDescription};try? await Task.sleep(for:.seconds(3))}}
    }
    func stop(){loop?.cancel();loop=nil;state = .disabled}

    private func upsertDevice(deviceKey:String,displayName:String,platform:String,worker:Bool,gui:Bool,lan:Bool) async throws -> UUID{
        struct Body:Encodable{let device_key:String;let display_name:String;let platform:String;let worker_online:Bool;let gui_online:Bool;let lan_online:Bool;let cloud_online:Bool;let last_seen_at:String}
        let b=Body(device_key:deviceKey,display_name:displayName,platform:platform,worker_online:worker,gui_online:gui,lan_online:lan,cloud_online:true,last_seen_at:ISO8601DateFormatter().string(from:Date()))
        let data=try await request(path:"/rest/v1/travis_devices?on_conflict=user_id,device_key",method:"POST",body:b,prefer:"resolution=merge-duplicates,return=representation");let values=try decoder.decode([Device].self,from:data);guard let id=values.first?.id else{throw CloudError.invalidResponse};return id
    }
    private func processCommands(for id:UUID) async throws{
        let now=ISO8601DateFormatter().string(from:Date()).addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? "";let data=try await request(path:"/rest/v1/travis_commands?target_device_id=eq.\(id.uuidString)&status=eq.queued&expires_at=gt.\(now)&order=created_at.asc&limit=20",method:"GET");let commands=try decoder.decode([Command].self,from:data)
        for c in commands{try await patchCommand(c.id,status:"acknowledged",result:nil);let out=execute(c);try await patchCommand(c.id,status:out.ok ? "completed":"failed",result:out.message)}
    }
    private func execute(_ c:Command)->(ok:Bool,message:String){switch c.command_type.lowercased(){case "kill_switch":let enabled=(c.payload?["enabled"] ?? "true").lowercased()=="true";do{try AlwaysOnWorkerMonitor.shared.setKillSwitch(enabled);return(true,enabled ? "Kill switch enabled":"Kill switch cleared")}catch{return(false,error.localizedDescription)};case "worker_job":guard let action=c.payload?["action"],let raw=c.payload?["job_id"],let id=UUID(uuidString:raw) else{return(false,"Malformed worker job command")};do{try AlwaysOnWorkerMonitor.shared.sendServiceJobCommand(action:action,jobID:id);return(true,"Worker command queued")}catch{return(false,error.localizedDescription)};default:return(false,"Command type is not allowlisted")}}
    private func patchCommand(_ id:UUID,status:String,result:String?) async throws{struct Patch:Encodable{let status:String;let acknowledged_at:String?;let completed_at:String?;let result:[String:String]?};let now=ISO8601DateFormatter().string(from:Date());let terminal=["completed","failed"].contains(status);let p=Patch(status:status,acknowledged_at:status=="acknowledged" ? now:nil,completed_at:terminal ? now:nil,result:result.map{["message":$0]});_ = try await request(path:"/rest/v1/travis_commands?id=eq.\(id.uuidString)",method:"PATCH",body:p)}
    func sendCommand(targetDeviceID:UUID,type:String,payload:[String:String]=[:]) async throws{struct Body:Encodable{let target_device_id:UUID;let command_type:String;let payload:[String:String];let expires_at:String};let b=Body(target_device_id:targetDeviceID,command_type:type,payload:payload,expires_at:ISO8601DateFormatter().string(from:Date().addingTimeInterval(300)));_ = try await request(path:"/rest/v1/travis_commands",method:"POST",body:b)}
    func devices() async throws->[Device]{let data=try await request(path:"/rest/v1/travis_devices?select=*&order=last_seen_at.desc",method:"GET");return try decoder.decode([Device].self,from:data)}

    private var decoder:JSONDecoder{let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return d}
    private func preparedRequest(path:String,method:String,prefer:String?) throws -> URLRequest{guard let token=accessToken,!token.isEmpty else{state = .unauthorized;throw CloudError.unauthorized};guard let url=URL(string:path,relativeTo:base) else{throw CloudError.invalidResponse};var r=URLRequest(url:url);r.httpMethod=method;r.setValue(publishableKey,forHTTPHeaderField:"apikey");r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type");if let prefer{r.setValue(prefer,forHTTPHeaderField:"Prefer")};return r}
    private func perform(_ r:URLRequest) async throws -> Data{let(data,response)=try await URLSession.shared.data(for:r);guard let h=response as? HTTPURLResponse else{throw CloudError.invalidResponse};guard 200..<300 ~= h.statusCode else{throw CloudError.http(h.statusCode,String(data:data,encoding:.utf8) ?? "")};return data}
    private func request(path:String,method:String,prefer:String?=nil) async throws -> Data{try await perform(preparedRequest(path:path,method:method,prefer:prefer))}
    private func request<B:Encodable>(path:String,method:String,body:B,prefer:String?=nil) async throws -> Data{var r=try preparedRequest(path:path,method:method,prefer:prefer);r.httpBody=try JSONEncoder().encode(body);return try await perform(r)}
    enum CloudError:LocalizedError{case unauthorized,invalidResponse,http(Int,String);var errorDescription:String?{switch self{case .unauthorized:return "Cloud authentication required";case .invalidResponse:return "Invalid cloud response";case let .http(code,msg):return "Cloud HTTP \(code): \(msg)"}}}
}
