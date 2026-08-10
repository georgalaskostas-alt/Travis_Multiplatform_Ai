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

        // TEMP DEBUG — remove once TTS audio output is confirmed working.
        print("[SpeechService] speak() text=\"\(text)\" languageCode=\(language.speechLanguageCode)")

        let utterance = AVSpeechUtterance(string: text)
        let voice = AVSpeechSynthesisVoice(language: language.speechLanguageCode)
        print("[SpeechService] resolved voice=\(String(describing: voice)) (nil means no voice matched that language code — likely cause of silence)")
        utterance.voice = voice
        print("[SpeechService] utterance.volume=\(utterance.volume) rate=\(utterance.rate)")

        synthesizer.speak(utterance)
        print("[SpeechService] synthesizer.speak() called, isSpeaking(engine)=\(synthesizer.isSpeaking)")
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("[SpeechService] delegate didStart")
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("[SpeechService] delegate didFinish")
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("[SpeechService] delegate didCancel")
        Task { @MainActor in self.isSpeaking = false }
    }
}
