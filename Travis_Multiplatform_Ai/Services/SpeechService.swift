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

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: AppLanguage) {
        guard !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.speechLanguageCode)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
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
