//
//  SyncService.swift
//  Travis_Multiplatform_Ai
//

import Foundation
import Observation

#if os(iOS) || os(macOS)
import MultipeerConnectivity
#endif

struct TravisBridgeStepSnapshot: Codable, Equatable, Identifiable {
    var id: UUID; var order: Int; var title: String; var status: String; var capability: String?; var attemptCount: Int; var maxAttempts: Int; var requiresApproval: Bool; var lastError: String?
}
struct TravisBridgeTaskSnapshot: Codable, Equatable, Identifiable {
    var id: UUID; var title: String; var goal: String; var status: String; var priority: String; var completedSteps: Int; var totalSteps: Int; var currentStep: String?; var checkpoint: String?; var finalReport: String?; var failureReason: String?; var steps: [TravisBridgeStepSnapshot]?; var updatedAt: Date
}
struct TravisBridgeStatusSnapshot: Codable, Equatable {
    var deviceName: String; var platform: String; var isBusy: Bool; var activeRuntimeTasks: Int; var lastSummary: String; var fccAvailable: Bool; var runtimeTasks: [TravisBridgeTaskSnapshot] = []; var alwaysOn: TravisBridgeAlwaysOnSnapshot? = nil
}
enum TravisBridgeCommand: Codable {
    case requestStatus
    case status(TravisBridgeStatusSnapshot)
    case openFCC
    case systemScan
    case runCommand(String)
    case speak(String)

    // Control Plane V2
    case controlCommand(TravisControlCommand)
    case controlResult(TravisControlCommandResult)
}

struct TravisControlCommandResult: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let commandID: UUID
    let status: TravisControlCommandStatus
    let message: String
    let completedAt: Date

    init(
        commandID: UUID,
        status: TravisControlCommandStatus,
        message: String
    ) {
        self.id = UUID()
        self.commandID = commandID
        self.status = status
        self.message = message
        self.completedAt = .now
    }
}

@Observable final class TravisDeviceBridgeService: NSObject {
    private static let controlPlaneDeviceIDKey = "travis.controlPlane.deviceID"

    var localDeviceID: UUID {
        if let raw = UserDefaults.standard.string(forKey: Self.controlPlaneDeviceIDKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }

        let created = UUID()
        UserDefaults.standard.set(
            created.uuidString,
            forKey: Self.controlPlaneDeviceIDKey
        )
        return created
    }

    static let shared=TravisDeviceBridgeService()
    private(set) var isRunning=false; private(set) var isConnected=false; private(set) var connectedPeerName:String?; private(set) var lastStatus:TravisBridgeStatusSnapshot?; private(set) var lastControlResult:TravisControlCommandResult?; private(set) var lastError:String?; private(set) var lastStatusReceivedAt:Date?
    var statusProvider:(()->TravisBridgeStatusSnapshot)?
    var onRemoteCommand:((String)->Void)?
    var onControlCommand:((TravisControlCommand)->Void)?
    var onControlResult:((TravisControlCommandResult)->Void)?
    var onSystemScan:(()->Void)?
    var onOpenFCC:(()->Void)?
    var onSpeak:((String)->Void)?
#if os(iOS) || os(macOS)
    @ObservationIgnored private let serviceType="travis-link"
    @ObservationIgnored private lazy var peerID=MCPeerID(displayName:Self.makePeerName())
    @ObservationIgnored private lazy var session:MCSession={let s=MCSession(peer:peerID,securityIdentity:nil,encryptionPreference:.required);s.delegate=self;return s}()
#if os(macOS)
    @ObservationIgnored private lazy var advertiser:MCNearbyServiceAdvertiser={let a=MCNearbyServiceAdvertiser(peer:peerID,discoveryInfo:["role":"mac"],serviceType:serviceType);a.delegate=self;return a}()
    @ObservationIgnored private lazy var pairingToken:String = {
        if let existing=TravisCloudCredentialStore.loadBridgePairingToken(),!existing.isEmpty{return existing}
        let created=UUID().uuidString.lowercased()
        try? TravisCloudCredentialStore.saveBridgePairingToken(created)
        return created
    }()
#else
    @ObservationIgnored private lazy var browser:MCNearbyServiceBrowser={let b=MCNearbyServiceBrowser(peer:peerID,serviceType:serviceType);b.delegate=self;return b}()
    @ObservationIgnored private var trustedPairingToken:String?{TravisCloudCredentialStore.loadBridgePairingToken()}
    @ObservationIgnored private var invitedPeers=Set<MCPeerID>(); @ObservationIgnored private var reconnectWorkItem:DispatchWorkItem?
#endif
#endif
    var isLANPaired:Bool{TravisCloudCredentialStore.loadBridgePairingToken()?.isEmpty == false}
#if os(macOS)
    var lanPairingCode:String{pairingToken}
    func rotateLANPairingCode(){
        let created=UUID().uuidString.lowercased()
        do{try TravisCloudCredentialStore.saveBridgePairingToken(created);pairingToken=created;session.disconnect();lastError="LAN pairing code rotated. Pair iPhone again."}catch{lastError=error.localizedDescription}
    }
#elseif os(iOS)
    func pairLAN(with code:String){
        let normalized=code.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard UUID(uuidString:normalized) != nil else{lastError="Invalid TRAVIS pairing code.";return}
        do{try TravisCloudCredentialStore.saveBridgePairingToken(normalized);lastError=nil;invitedPeers.removeAll();session.disconnect();if isRunning{browser.stopBrowsingForPeers();browser.startBrowsingForPeers()}}catch{lastError=error.localizedDescription}
    }
    func forgetLANPairing(){TravisCloudCredentialStore.clearBridgePairingToken();session.disconnect();invitedPeers.removeAll();lastError="LAN pairing removed."}
#endif
    private override init(){super.init()}
    func start(){guard !isRunning else{return};isRunning=true;lastError=nil
#if os(macOS)
        advertiser.startAdvertisingPeer()
#elseif os(iOS)
        browser.startBrowsingForPeers()
#endif
    }
    func stop(){guard isRunning else{return};isRunning=false
#if os(macOS)
        advertiser.stopAdvertisingPeer()
#elseif os(iOS)
        reconnectWorkItem?.cancel();reconnectWorkItem=nil;browser.stopBrowsingForPeers();invitedPeers.removeAll()
#endif
#if os(iOS) || os(macOS)
        session.disconnect()
#endif
        updateConnectionState(peer:nil,connected:false)
    }
    func requestStatus(){send(.requestStatus)}
    func openFCCOnMac(){send(.openFCC)}
    func runSystemScanOnMac(){send(.systemScan)}

    func sendControlCommand(_ command: TravisControlCommand) {
        send(.controlCommand(command))
    }

    func sendControlResult(_ result: TravisControlCommandResult) {
        send(.controlResult(result))
    }
    func sendCommandToMac(_ text:String){let t=text.trimmingCharacters(in:.whitespacesAndNewlines);guard !t.isEmpty else{return};send(.runCommand(t))}
    func speakOnMac(_ text:String){let t=text.trimmingCharacters(in:.whitespacesAndNewlines);guard !t.isEmpty else{return};send(.speak(t))}
    private func send(_ command:TravisBridgeCommand){
#if os(iOS) || os(macOS)
        let peers=session.connectedPeers;guard !peers.isEmpty else{DispatchQueue.main.async{[weak self] in self?.lastError="Mac connection unavailable";self?.isConnected=false;self?.connectedPeerName=nil
#if os(iOS)
            self?.scheduleReconnect(reason:"transport unavailable")
#endif
        };return}
        do{try session.send(try JSONEncoder().encode(command),toPeers:peers,with:.reliable)}catch{DispatchQueue.main.async{[weak self] in self?.lastError=error.localizedDescription;self?.isConnected=false;self?.connectedPeerName=nil
#if os(iOS)
            self?.scheduleReconnect(reason:"send failed")
#endif
        }}
#endif
    }
    private func handle(_ command: TravisBridgeCommand) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch command {
            case .requestStatus:
                if let snapshot = self.statusProvider?() {
                    self.send(.status(snapshot))
                }

            case .status(let snapshot):
                self.lastStatus = snapshot
                self.lastStatusReceivedAt = Date()
                self.lastError = nil

            case .openFCC:
                self.onOpenFCC?()

            case .systemScan:
                self.onSystemScan?()

            case .runCommand(let text):
                self.onRemoteCommand?(text)

            case .speak(let text):
                self.onSpeak?(text)

            case .controlCommand(let controlCommand):
                self.onControlCommand?(controlCommand)

            case .controlResult(let result):
                self.lastControlResult = result
                self.onControlResult?(result)
            }
        }
    }
    private func updateConnectionState(peer:MCPeerID?,connected:Bool){DispatchQueue.main.async{[weak self] in guard let self else{return};self.isConnected=connected;self.connectedPeerName=connected ? peer?.displayName:nil;if connected{self.lastError=nil
#if os(iOS)
        self.reconnectWorkItem?.cancel();self.reconnectWorkItem=nil;self.requestStatus()
#endif
    }}}
#if os(iOS)
    private func scheduleReconnect(reason:String){guard isRunning else{return};reconnectWorkItem?.cancel();let w=DispatchWorkItem{[weak self] in guard let self,self.isRunning,!self.isConnected else{return};self.invitedPeers.removeAll();self.browser.stopBrowsingForPeers();self.session.disconnect();DispatchQueue.main.asyncAfter(deadline:.now()+0.35){[weak self] in guard let self,self.isRunning,!self.isConnected else{return};self.lastError="Reconnecting to Mac TRAVIS…";self.browser.startBrowsingForPeers()}};reconnectWorkItem=w;lastError="Connection lost (\(reason)). Reconnecting…";DispatchQueue.main.asyncAfter(deadline:.now()+0.75,execute:w)}
#endif
    private static func makePeerName()->String{let base=ProcessInfo.processInfo.hostName.replacingOccurrences(of:".local",with:"").prefix(36)
#if os(macOS)
        return "TRAVIS-Mac-\(base)"
#elseif os(iOS)
        return "TRAVIS-iPhone-\(base)"
#else
        return "TRAVIS-\(base)"
#endif
    }
}
#if os(iOS) || os(macOS)
extension TravisDeviceBridgeService:MCSessionDelegate{
    func session(_ session:MCSession,peer peerID:MCPeerID,didChange state:MCSessionState){switch state{case .connected:updateConnectionState(peer:peerID,connected:true);case .notConnected:updateConnectionState(peer:peerID,connected:false)
#if os(iOS)
        DispatchQueue.main.async{[weak self] in self?.invitedPeers.remove(peerID);self?.scheduleReconnect(reason:"peer disconnected")}
#endif
    case .connecting:break;@unknown default:break}}
    func session(_ session:MCSession,didReceive data:Data,fromPeer peerID:MCPeerID){do{handle(try JSONDecoder().decode(TravisBridgeCommand.self,from:data))}catch{DispatchQueue.main.async{[weak self] in self?.lastError="Bridge decode failed: \(error.localizedDescription)"}}}
    func session(_ session:MCSession,didReceive stream:InputStream,withName streamName:String,fromPeer peerID:MCPeerID){}
    func session(_ session:MCSession,didStartReceivingResourceWithName resourceName:String,fromPeer peerID:MCPeerID,with progress:Progress){}
    func session(_ session:MCSession,didFinishReceivingResourceWithName resourceName:String,fromPeer peerID:MCPeerID,at localURL:URL?,withError error:Error?){}
}
#if os(macOS)
extension TravisDeviceBridgeService:MCNearbyServiceAdvertiserDelegate{func advertiser(_ advertiser:MCNearbyServiceAdvertiser,didReceiveInvitationFromPeer peerID:MCPeerID,withContext context:Data?,invitationHandler:@escaping(Bool,MCSession?)->Void){guard let context,let token=String(data:context,encoding:.utf8),token==pairingToken else{invitationHandler(false,nil);return};invitationHandler(true,session)};func advertiser(_ advertiser:MCNearbyServiceAdvertiser,didNotStartAdvertisingPeer error:Error){DispatchQueue.main.async{[weak self] in self?.lastError=error.localizedDescription}}}
#elseif os(iOS)
extension TravisDeviceBridgeService:MCNearbyServiceBrowserDelegate{func browser(_ browser:MCNearbyServiceBrowser,foundPeer peerID:MCPeerID,withDiscoveryInfo info:[String:String]?){guard info?["role"]=="mac",!invitedPeers.contains(peerID) else{return};guard let token=trustedPairingToken,!token.isEmpty else{DispatchQueue.main.async{[weak self] in self?.lastError="Mac pairing required before LAN control can connect."};return};invitedPeers.insert(peerID);browser.invitePeer(peerID,to:session,withContext:Data(token.utf8),timeout:12)};func browser(_ browser:MCNearbyServiceBrowser,lostPeer peerID:MCPeerID){invitedPeers.remove(peerID)};func browser(_ browser:MCNearbyServiceBrowser,didNotStartBrowsingForPeers error:Error){DispatchQueue.main.async{[weak self] in self?.lastError=error.localizedDescription;self?.scheduleReconnect(reason:"browser failed")}}}
#endif
#endif
