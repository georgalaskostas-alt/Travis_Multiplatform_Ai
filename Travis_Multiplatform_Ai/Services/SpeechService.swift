import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class SpeechService: NSObject {
    static let shared = SpeechService()

    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinishedSpeaking: (() -> Void)?

    private static let pitchMultiplier: Float = 0.75
    private static let rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.85

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: AppLanguage, completion: (() -> Void)? = nil) {
        guard !text.isEmpty else { completion?(); return }
        onFinishedSpeaking = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableVoice(for: language.speechLanguageCode)
        utterance.pitchMultiplier = Self.pitchMultiplier
        utterance.rate = Self.rate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }

    private static func bestAvailableVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        if let premium = matchingVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = matchingVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: languageCode)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    private func finishedSpeaking() {
        isSpeaking = false
        let completion = onFinishedSpeaking
        onFinishedSpeaking = nil
        completion?()
    }
}

#if os(macOS)
@MainActor
final class PrivateAudioProfileService: NSObject, AVAudioPlayerDelegate {
    static let shared = PrivateAudioProfileService()

    enum PrivateAudioKind {
        case startup, voiceReference
        var storedFilename: String { self == .startup ? "startup-sound.mp3" : "voice-reference.mp3" }
    }

    private var startupPlayer: AVAudioPlayer?
    private var startupSequenceTask: Task<Void, Never>?
    private override init() { super.init() }

    var privateDirectoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TRAVIS", isDirectory: true)
            .appendingPathComponent("PrivateAudio", isDirectory: true)
    }
    func storedURL(for kind: PrivateAudioKind) -> URL? { privateDirectoryURL?.appendingPathComponent(kind.storedFilename) }
    func isConfigured(_ kind: PrivateAudioKind) -> Bool {
        guard let url = storedURL(for: kind) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    func importPrivateAudio(kind: PrivateAudioKind) -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
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
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return true
        } catch {
            print("[PrivateAudioProfileService] Failed to store private audio: \(error)"); return false
        }
    }

    func remove(_ kind: PrivateAudioKind) {
        guard let url = storedURL(for: kind), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func playStartupSoundIfConfigured() {
        guard let url = storedURL(for: .startup), FileManager.default.fileExists(atPath: url.path) else { return }
        do { startupPlayer = try AVAudioPlayer(contentsOf: url); startupPlayer?.delegate = self; startupPlayer?.prepareToPlay(); startupPlayer?.play() }
        catch { print("[PrivateAudioProfileService] Startup playback failed: \(error)") }
    }

    func playStartupSequence(greeting: String, language: AppLanguage) {
        startupSequenceTask?.cancel()
        startupSequenceTask = Task { @MainActor in
            let trimmed = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasMusic = startLoopingStartupMusic()
            if hasMusic {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                startupPlayer?.setVolume(0.22, fadeDuration: 0.55)
            }

            let briefing = taskBriefing(language: language)
            let spokenText = [trimmed, briefing].filter { !$0.isEmpty }.joined(separator: " ")
            guard !spokenText.isEmpty else { scheduleMusicFadeOut(); return }

            SpeechService.shared.speak(spokenText, language: language) { [weak self] in
                self?.scheduleMusicFadeOut()
            }
        }
    }

    private func taskBriefing(language: AppLanguage) -> String {
        let tasks = AgentTaskStore.shared.loadForStatusBriefing()
        let active = tasks.filter { [.pending, .planning, .running, .waitingForApproval, .waitingForDependency, .paused].contains($0.status) }
        guard !active.isEmpty else { return "Δεν υπάρχουν εργασίες σε εξέλιξη αυτή τη στιγμή." }

        let running = active.filter { $0.status == .running }
        let waitingApproval = active.filter { $0.status == .waitingForApproval }
        let paused = active.filter { $0.status == .paused }
        var parts = ["Υπάρχουν \(active.count) ενεργές εργασίες."]
        if !running.isEmpty { parts.append("\(running.count) εκτελούνται αυτή τη στιγμή.") }
        if !waitingApproval.isEmpty { parts.append("\(waitingApproval.count) περιμένουν έγκριση.") }
        if !paused.isEmpty { parts.append("\(paused.count) είναι σε παύση.") }
        for task in active.prefix(3) {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { parts.append("Εργασία: \(title).") }
        }
        if active.count > 3 { parts.append("Υπάρχουν ακόμη \(active.count - 3) ενεργές εργασίες.") }
        return parts.joined(separator: " ")
    }

    private func startLoopingStartupMusic() -> Bool {
        guard let url = storedURL(for: .startup), FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let player = try AVAudioPlayer(contentsOf: url); startupPlayer = player; player.delegate = self
            player.numberOfLoops = -1; player.volume = 0.72; player.prepareToPlay(); return player.play()
        } catch { print("[PrivateAudioProfileService] Startup sequence playback failed: \(error)"); return false }
    }

    private func scheduleMusicFadeOut() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.fadeOutStartupMusic()
        }
    }

    private func fadeOutStartupMusic() {
        guard let player = startupPlayer else { return }
        player.setVolume(0.0, fadeDuration: 2.0)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(for: .milliseconds(2100)); player?.stop()
            if self?.startupPlayer === player { self?.startupPlayer = nil }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === startupPlayer { startupPlayer = nil }
    }
}
#else
@MainActor
final class PrivateAudioProfileService {
    static let shared = PrivateAudioProfileService()
    enum PrivateAudioKind { case startup, voiceReference }
    private init() {}
    func isConfigured(_ kind: PrivateAudioKind) -> Bool { false }
    func playStartupSoundIfConfigured() {}
    func playStartupSequence(greeting: String, language: AppLanguage) {}
}
#endif
