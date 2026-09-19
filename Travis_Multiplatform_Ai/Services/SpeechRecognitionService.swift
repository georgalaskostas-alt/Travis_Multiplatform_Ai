import Foundation
import Speech
import AVFoundation

/// Speech-to-text half of voice mode — captures the microphone live via
/// `AVAudioEngine` and transcribes it with `SFSpeechRecognizer` while
/// `TRAVISAppState.isListening` is on. Companion to `SpeechService`.
///
/// Final transcripts pass through a semantic intent classifier before they
/// reach the general orchestrator. Local application actions are therefore
/// understood from meaning rather than hard-coded phrases, while the actual
/// side effect remains deterministic inside the app.
@MainActor
@Observable
final class SpeechRecognitionService: NSObject {
    static let shared = SpeechRecognitionService()

    private static let deleteLatestConversationNotification = Notification.Name("TRAVISDeleteLatestConversation")
    private static let stopAutonomousExecutionNotification = Notification.Name("TRAVISStopAutonomousExecution")

    private(set) var isListening = false
    private(set) var liveTranscript = ""

    var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

    private static let silenceTimeout: TimeInterval = 1.5

    private override init() {
        super.init()
    }

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

    func stop() {
        teardownCapture(sendFinalTranscript: false)
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
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

        guard sendFinalTranscript, !finalText.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if await self.consumeLocalSemanticIntent(finalText) {
                return
            }

            self.onFinalTranscript?(finalText)
        }
    }

    // MARK: - Semantic Voice Intent

    private struct VoiceIntent: Decodable {
        let intent: String
        let confidence: Double
        let target: String?
        let needsClarification: Bool
    }

    private func consumeLocalSemanticIntent(_ transcript: String) async -> Bool {
        let prompt = """
        You are the semantic command router for TRAVIS, a personal AI assistant.

        Understand the USER'S MEANING, not keywords or exact phrases.
        The user may speak Greek, English, mixed language, slang, pronouns, or elliptical phrases.

        USER TRANSCRIPT:
        \(transcript)

        Supported LOCAL intents:
        - delete_conversation: remove/delete a conversation from TRAVIS history.
        - stop_execution: stop/pause/cancel the autonomous task or execution that is currently running.
        - none: anything else.

        Interpret naturally. For example all of these mean stop_execution:
        - "σταμάτα αυτό που κάνεις"
        - "άστο εδώ για τώρα"
        - "παύσε το task"
        - "μη συνεχίσεις άλλο"
        - "stop the current run"
        - "cancel what is running"

        For delete_conversation target values are:
        - latest
        - viewed
        - unspecified

        For stop_execution target should be "active".
        For none target should be null.

        Safety:
        - If a destructive deletion target is ambiguous, set needsClarification true.
        - stop_execution is reversible and may be classified when the intent is clear.
        - If intent itself is uncertain, return none.

        Return ONLY valid JSON, no markdown:
        {
          "intent": "delete_conversation|stop_execution|none",
          "confidence": 0.0,
          "target": "latest|viewed|unspecified|active|null",
          "needsClarification": false
        }
        """

        do {
            let raw = try await AIService.shared.generateText(prompt: prompt, maxTokens: 220)
            let cleaned = cleanJSON(raw)
            guard let data = cleaned.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(VoiceIntent.self, from: data)
            else {
                return false
            }

            guard parsed.confidence >= 0.72 else { return false }

            switch parsed.intent {
            case "stop_execution":
                NotificationCenter.default.post(
                    name: Self.stopAutonomousExecutionNotification,
                    object: transcript
                )
                return true

            case "delete_conversation":
                if parsed.needsClarification || parsed.target == "unspecified" {
                    onFinalTranscript?("Θέλω να διαγράψω μια συνομιλία, αλλά δεν είναι σαφές ποια. Ρώτησέ με ποια συνομιλία εννοώ πριν διαγράψεις οτιδήποτε.")
                    return true
                }

                NotificationCenter.default.post(
                    name: Self.deleteLatestConversationNotification,
                    object: parsed.target ?? "latest"
                )
                return true

            default:
                return false
            }

        } catch {
            return false
        }
    }

    private func cleanJSON(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json") {
            value.removeFirst("```json".count)
        } else if value.hasPrefix("```") {
            value.removeFirst(3)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("```") {
            value.removeLast(3)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
