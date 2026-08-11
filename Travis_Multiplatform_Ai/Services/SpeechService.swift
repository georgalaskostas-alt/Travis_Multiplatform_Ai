import Foundation
import AVFoundation

/// Text-to-speech only, for now — reads TRAVIS's replies aloud via
/// `AVSpeechSynthesizer` when voice mode is on. Speech *recognition*
/// (listening back) is a separate, not-yet-built step; the
/// NSSpeechRecognitionUsageDescription/NSMicrophoneUsageDescription
/// Info.plist keys were added ahead of that work, but nothing here
/// touches the microphone.
///
/// `NSObject` subclass because `AVSpeechSynthesizerDelegate` is an
/// Objective-C protocol. Delegate callbacks are `nonisolated` since
/// AVFoundation can call them from any thread; each one hops back to the
/// MainActor to update `isSpeaking`, which is what `@MainActor`-isolated
/// SwiftUI code (and `TRAVISAppState`) actually reads.
@MainActor
@Observable
final class SpeechService: NSObject {
    static let shared = SpeechService()

    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    /// Lower than the neutral 1.0 for a deeper, more "Jarvis"-like tone
    /// without distorting into a robotic growl.
    private static let pitchMultiplier: Float = 0.88
    /// Slightly slower than the system default for a measured,
    /// authoritative delivery.
    private static let rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.9

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: AppLanguage) {
        guard !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableVoice(for: language.speechLanguageCode)
        utterance.pitchMultiplier = Self.pitchMultiplier
        utterance.rate = Self.rate

        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Prefers a higher-quality installed voice (`.premium`, then
    /// `.enhanced`) for the given language over the always-available
    /// `.default` compact one — those read noticeably more natural and
    /// deep. Falls back to whatever `AVSpeechSynthesisVoice(language:)`
    /// resolves to (including `nil`) if no such voice is installed.
    private static func bestAvailableVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == languageCode }

        if let premium = matchingVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = matchingVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
