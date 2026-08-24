//
//  SyncService.swift
//  Travis_Multiplatform_Ai
//
//  Created by Κωνσταντινος Γεωργαλας on 3/6/26.
//

import Foundation
import Observation

#if os(iOS) || os(macOS)
import MultipeerConnectivity
#endif

struct TravisBridgeStatusSnapshot: Codable, Equatable {
    var deviceName: String
    var platform: String
    var isBusy: Bool
    var activeRuntimeTasks: Int
    var lastSummary: String
    var fccAvailable: Bool
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

    var statusProvider: (() -> TravisBridgeStatusSnapshot)?
    var onRemoteCommand: ((String) -> Void)?
    var onSystemScan: (() -> Void)?
    var onOpenFCC: (() -> Void)?
    var onSpeak: ((String) -> Void)?

    #if os(iOS) || os(macOS)
    private let serviceType = "travis-link"
    private lazy var peerID = MCPeerID(displayName: Self.makePeerName())
    private lazy var session: MCSession = {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()

    #if os(macOS)
    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["role": "mac"], serviceType: serviceType)
        advertiser.delegate = self
        return advertiser
    }()
    #else
    private lazy var browser: MCNearbyServiceBrowser = {
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        return browser
    }()
    private var invitedPeers = Set<MCPeerID>()
    #endif
    #endif

    private override init() {
        super.init()
    }

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
        guard !session.connectedPeers.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Mac connection unavailable"
                self?.isConnected = false
            }
            return
        }

        do {
            let data = try JSONEncoder().encode(command)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
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
                self.lastError = nil
            case .openFCC:
                self.onOpenFCC?()
            case .systemScan:
                self.onSystemScan?()
            case .runCommand(let text):
                self.onRemoteCommand?(text)
            case .speak(let text):
                self.onSpeak?(text)
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
                self.requestStatus()
                #endif
            }
        }
    }

    private static func makePeerName() -> String {
        let base = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .prefix(36)
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
        case .connected:
            updateConnectionState(peer: peerID, connected: true)
        case .notConnected:
            updateConnectionState(peer: peerID, connected: false)
            #if os(iOS)
            DispatchQueue.main.async { [weak self] in self?.invitedPeers.remove(peerID) }
            #endif
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let command = try JSONDecoder().decode(TravisBridgeCommand.self, from: data)
            handle(command)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Invalid bridge payload: \(error.localizedDescription)"
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif

#if os(macOS)
extension TravisDeviceBridgeService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
    }
}
#endif

#if os(iOS)
extension TravisDeviceBridgeService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard info?["role"] == "mac", !invitedPeers.contains(peerID) else { return }
        invitedPeers.insert(peerID)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitedPeers.remove(peerID)
        if connectedPeerName == peerID.displayName {
            updateConnectionState(peer: peerID, connected: false)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
    }
}
#endif
