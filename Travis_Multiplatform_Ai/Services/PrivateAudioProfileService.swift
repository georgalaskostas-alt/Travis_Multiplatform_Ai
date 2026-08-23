import Foundation
import AVFoundation

#if os(macOS)
import AppKit

@MainActor
final class PrivateAudioProfileService: NSObject, AVAudioPlayerDelegate {
    static let shared = PrivateAudioProfileService()

    enum PrivateAudioKind {
        case startup
        case voiceReference

        var storedFilename: String {
            switch self {
            case .startup: return "startup-sound.mp3"
            case .voiceReference: return "voice-reference.mp3"
            }
        }
    }

    private var startupPlayer: AVAudioPlayer?

    private override init() {
        super.init()
    }

    var privateDirectoryURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("TRAVIS", isDirectory: true)
            .appendingPathComponent("PrivateAudio", isDirectory: true)
    }

    func storedURL(for kind: PrivateAudioKind) -> URL? {
        privateDirectoryURL?.appendingPathComponent(kind.storedFilename)
    }

    func isConfigured(_ kind: PrivateAudioKind) -> Bool {
        guard let url = storedURL(for: kind) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    func importPrivateAudio(kind: PrivateAudioKind) -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.title = kind == .startup ? "Choose TRAVIS startup sound" : "Choose private TRAVIS voice reference"
        panel.prompt = "Use File"

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return false }
        return store(sourceURL: sourceURL, as: kind)
    }

    @discardableResult
    func store(sourceURL: URL, as kind: PrivateAudioKind) -> Bool {
        guard let directory = privateDirectoryURL, let destination = storedURL(for: kind) else { return false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return true
        } catch {
            print("[PrivateAudioProfileService] Failed to store \(kind): \(error)")
            return false
        }
    }

    func remove(_ kind: PrivateAudioKind) {
        guard let url = storedURL(for: kind), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func playStartupSoundIfConfigured() {
        guard let url = storedURL(for: .startup), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            startupPlayer = try AVAudioPlayer(contentsOf: url)
            startupPlayer?.delegate = self
            startupPlayer?.prepareToPlay()
            startupPlayer?.play()
        } catch {
            print("[PrivateAudioProfileService] Startup playback failed: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === startupPlayer {
            startupPlayer = nil
        }
    }
}

#else

@MainActor
final class PrivateAudioProfileService {
    static let shared = PrivateAudioProfileService()

    enum PrivateAudioKind {
        case startup
        case voiceReference
    }

    private init() {}
    func isConfigured(_ kind: PrivateAudioKind) -> Bool { false }
    func playStartupSoundIfConfigured() {}
}

#endif
