import Foundation
import AVFoundation

/// Text-to-speech half of voice mode — reads TRAVIS's replies aloud via
/// `AVSpeechSynthesizer` when voice mode is on. Speech *recognition*
/// (listening) is the companion `SpeechRecognitionService`; the two
/// coordinate through `speak(_:language:completion:)`'s completion
/// handler so they never capture/play audio at the same time — see
/// `TRAVISAppState.addAssistantMessage`.
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

    /// Invoked once when the in-flight utterance finishes or is
    /// cancelled — lets `TRAVISAppState` resume speech *recognition*
    /// after TRAVIS is done talking (see `speak(_:language:completion:)`).
    private var onFinishedSpeaking: (() -> Void)?

    /// Lower than the neutral 1.0 for a deeper, more "Jarvis"-like tone
    /// without distorting into a robotic growl.
    private static let pitchMultiplier: Float = 0.75
    /// Slower than the system default for a measured, authoritative
    /// delivery.
    private static let rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.85

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: AppLanguage, completion: (() -> Void)? = nil) {
        guard !text.isEmpty else {
            completion?()
            return
        }

        onFinishedSpeaking = completion

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

        let chosen: AVSpeechSynthesisVoice?
        if let premium = matchingVoices.first(where: { $0.quality == .premium }) {
            chosen = premium
        } else if let enhanced = matchingVoices.first(where: { $0.quality == .enhanced }) {
            chosen = enhanced
        } else {
            chosen = AVSpeechSynthesisVoice(language: languageCode)
        }

        // TEMP DEBUG — confirms which actual voice gets used; remove once
        // we've verified an enhanced/premium voice is available on-device.
        print("[SpeechService] \(matchingVoices.count) voice(s) installed for \(languageCode): "
            + matchingVoices.map { "\($0.name) [\($0.identifier)] quality=\($0.quality.rawValue)" }.joined(separator: ", "))
        if let chosen {
            print("[SpeechService] chosen voice: \(chosen.name) [\(chosen.identifier)] quality=\(chosen.quality.rawValue)")
        } else {
            print("[SpeechService] chosen voice: nil (no voice resolved for \(languageCode))")
        }

        return chosen
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
