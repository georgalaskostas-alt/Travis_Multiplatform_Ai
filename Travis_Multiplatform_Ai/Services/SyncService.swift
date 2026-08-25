//
//  SyncService.swift
//  Travis_Multiplatform_Ai
//

import Foundation
import Observation

#if os(iOS) || os(macOS)
import MultipeerConnectivity
#endif

struct TravisBridgeTaskSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var goal: String
    var status: String
    var priority: String
    var completedSteps: Int
    var totalSteps: Int
    var currentStep: String?
    var checkpoint: String?
    var updatedAt: Date
}

struct TravisBridgeStatusSnapshot: Codable, Equatable {
    var deviceName: String
    var platform: String
    var isBusy: Bool
    var activeRuntimeTasks: Int
    var lastSummary: String
    var fccAvailable: Bool
    var runtimeTasks: [TravisBridgeTaskSnapshot] = []
}

enum TravisBridgeCommand: Codable, Equatable {
    case requestStatus
    case status(TravisBridgeStatusSnapshot)
    case openFCC
    case systemScan
    case runCommand(String)
    case speak(String)
}

@Observable
final class TravisDeviceBridgeService: NSObject {
    static let shared = TravisDeviceBridgeService()

    private(set) var isRunning = false
    private(set) var isConnected = false
    private(set) var connectedPeerName: String?
    private(set) var lastStatus: TravisBridgeStatusSnapshot?
    private(set) var lastError: String?
    private(set) var lastStatusReceivedAt: Date?

    var statusProvider: (() -> TravisBridgeStatusSnapshot)?
    var onRemoteCommand: ((String) -> Void)?
    var onSystemScan: (() -> Void)?
    var onOpenFCC: (() -> Void)?
    var onSpeak: ((String) -> Void)?

    #if os(iOS) || os(macOS)
    @ObservationIgnored private let serviceType = "travis-link"
    @ObservationIgnored private lazy var peerID = MCPeerID(displayName: Self.makePeerName())
    @ObservationIgnored private lazy var session: MCSession = {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()

    #if os(macOS)
    @ObservationIgnored private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["role": "mac"], serviceType: serviceType)
        advertiser.delegate = self
        return advertiser
    }()
    #else
    @ObservationIgnored private lazy var browser: MCNearbyServiceBrowser = {
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        return browser
    }()
    @ObservationIgnored private var invitedPeers = Set<MCPeerID>()
    @ObservationIgnored private var reconnectWorkItem: DispatchWorkItem?
    #endif
    #endif

    private override init() { super.init() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        #if os(macOS)
        advertiser.startAdvertisingPeer()
        #elseif os(iOS)
        browser.startBrowsingForPeers()
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        #if os(macOS)
        advertiser.stopAdvertisingPeer()
        #elseif os(iOS)
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        browser.stopBrowsingForPeers()
        invitedPeers.removeAll()
        #endif
        #if os(iOS) || os(macOS)
        session.disconnect()
        #endif
        updateConnectionState(peer: nil, connected: false)
    }

    func requestStatus() { send(.requestStatus) }
    func openFCCOnMac() { send(.openFCC) }
    func runSystemScanOnMac() { send(.systemScan) }

    func sendCommandToMac(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.runCommand(trimmed))
    }

    func speakOnMac(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.speak(trimmed))
    }

    private func send(_ command: TravisBridgeCommand) {
        #if os(iOS) || os(macOS)
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastError = "Mac connection unavailable"
                self.isConnected = false
                self.connectedPeerName = nil
                #if os(iOS)
                self.scheduleReconnect(reason: "transport unavailable")
                #endif
            }
            return
        }
        do {
            let data = try JSONEncoder().encode(command)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastError = error.localizedDescription
                self.isConnected = false
                self.connectedPeerName = nil
                #if os(iOS)
                self.scheduleReconnect(reason: "send failed")
                #endif
            }
        }
        #endif
    }

    private func handle(_ command: TravisBridgeCommand) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch command {
            case .requestStatus:
                if let snapshot = self.statusProvider?() { self.send(.status(snapshot)) }
            case .status(let snapshot):
                self.lastStatus = snapshot
                self.lastStatusReceivedAt = Date()
                self.lastError = nil
            case .openFCC: self.onOpenFCC?()
            case .systemScan: self.onSystemScan?()
            case .runCommand(let text): self.onRemoteCommand?(text)
            case .speak(let text): self.onSpeak?(text)
            }
        }
    }

    private func updateConnectionState(peer: MCPeerID?, connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = connected
            self.connectedPeerName = connected ? peer?.displayName : nil
            if connected {
                self.lastError = nil
                #if os(iOS)
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
                self.requestStatus()
                #endif
            }
        }
    }

    #if os(iOS)
    private func scheduleReconnect(reason: String) {
        guard isRunning else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.isConnected else { return }
            self.invitedPeers.removeAll()
            self.browser.stopBrowsingForPeers()
            self.session.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.isRunning, !self.isConnected else { return }
                self.lastError = "Reconnecting to Mac TRAVIS…"
                self.browser.startBrowsingForPeers()
            }
        }
        reconnectWorkItem = workItem
        lastError = "Connection lost (\(reason)). Reconnecting…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }
    #endif

    private static func makePeerName() -> String {
        let base = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "").prefix(36)
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
extension TravisDeviceBridgeService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected: updateConnectionState(peer: peerID, connected: true)
        case .notConnected:
            updateConnectionState(peer: peerID, connected: false)
            #if os(iOS)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.invitedPeers.remove(peerID)
                self.scheduleReconnect(reason: "peer disconnected")
            }
            #endif
        case .connecting:
            DispatchQueue.main.async { [weak self] in self?.lastError = "Connecting to Mac TRAVIS…" }
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do { handle(try JSONDecoder().decode(TravisBridgeCommand.self, from: data)) }
        catch { DispatchQueue.main.async { [weak self] in self?.lastError = "Invalid bridge payload: \(error.localizedDescription)" } }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif

#if os(macOS)
extension TravisDeviceBridgeService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) { invitationHandler(true, session) }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription } }
}
#endif

#if os(iOS)
extension TravisDeviceBridgeService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard info?["role"] == "mac", !isConnected, !invitedPeers.contains(peerID) else { return }
        invitedPeers.insert(peerID)
        lastError = "Mac TRAVIS found. Connecting…"
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitedPeers.remove(peerID)
        if connectedPeerName == peerID.displayName {
            updateConnectionState(peer: peerID, connected: false)
            scheduleReconnect(reason: "peer lost")
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastError = error.localizedDescription
            self.scheduleReconnect(reason: "browser failed")
        }
    }
}
#endif
