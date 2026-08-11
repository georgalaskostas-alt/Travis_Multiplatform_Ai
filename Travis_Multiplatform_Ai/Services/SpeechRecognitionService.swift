import Foundation
import Speech
import AVFoundation

/// Speech-to-text half of voice mode — captures the microphone live via
/// `AVAudioEngine` and transcribes it with `SFSpeechRecognizer` while
/// `TRAVISAppState.isListening` is on. Companion to `SpeechService`
/// (text-to-speech); the two never run their audio I/O at the same
/// time — see the pause/resume coordination in
/// `TRAVISAppState.addAssistantMessage`, which stops recognition before
/// TRAVIS speaks and restarts it once the reply finishes, so the
/// microphone never picks up TRAVIS's own voice as a new command.
///
/// `NSObject` subclass for the same reason as `SpeechService`: framework
/// delegate/callback types here aren't actor-isolated, so callbacks hop
/// back to the MainActor explicitly.
@MainActor
@Observable
final class SpeechRecognitionService: NSObject {
    static let shared = SpeechRecognitionService()

    /// Whether the microphone is actively capturing right now — distinct
    /// from `TRAVISAppState.isListening`, which tracks whether voice mode
    /// is on overall (recognition pauses during TTS playback without
    /// voice mode itself turning off).
    private(set) var isListening = false
    /// The in-progress transcription, updated live as the user talks and
    /// shown in the UI before anything is sent.
    private(set) var liveTranscript = ""

    /// Fired with the finished utterance once silence is detected. Not
    /// fired when listening is stopped explicitly (`stop()`) with nothing
    /// meaningful said yet.
    var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

    /// How long to wait after the last new word before treating the
    /// utterance as finished.
    private static let silenceTimeout: TimeInterval = 1.5

    private override init() {
        super.init()
    }

    /// Requests speech-recognition + microphone authorization (only
    /// actually prompts the first time; subsequent calls resolve
    /// immediately from the cached OS decision) and starts capturing on
    /// success. No-ops if already listening.
    func start(language: AppLanguage) {
        guard !isListening else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard let self, authStatus == .authorized else { return }

                self.requestMicrophoneAccess { granted in
                    guard granted else { return }
                    self.beginCapture(language: language)
                }
            }
        }
    }

    /// Stops capturing without sending whatever partial transcript exists
    /// — used for the explicit "Stop Listening" toggle, which is a
    /// cancel, not a submit.
    func stop() {
        teardownCapture(sendFinalTranscript: false)
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        // AVCaptureDevice's permission API is used (rather than
        // AVAudioSession.requestRecordPermission) because it's the one
        // microphone-permission entry point common to both iOS and native
        // macOS — AVAudioSession itself doesn't exist on macOS at all,
        // see the #if os(macOS) guard below.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    private func beginCapture(language: AppLanguage) {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SpeechRecognitionService] audio session error: \(error)")
            return
        }
        #endif

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLanguageCode)),
              recognizer.isAvailable else {
            print("[SpeechRecognitionService] no available recognizer for \(language.speechLanguageCode)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[SpeechRecognitionService] audio engine start error: \(error)")
            recognitionRequest = nil
            return
        }

        isListening = true
        liveTranscript = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                }

                if error != nil {
                    self.teardownCapture(sendFinalTranscript: false)
                } else if result?.isFinal == true {
                    self.teardownCapture(sendFinalTranscript: true)
                }
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Self.silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.teardownCapture(sendFinalTranscript: true) }
        }
    }

    private func teardownCapture(sendFinalTranscript: Bool) {
        guard isListening else { return }

        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        isListening = false

        let finalText = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscript = ""

        if sendFinalTranscript, !finalText.isEmpty {
            onFinalTranscript?(finalText)
        }
    }
}
