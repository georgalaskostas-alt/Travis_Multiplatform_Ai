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

    private(set) var isListening = false
    private(set) var liveTranscript = ""

    /// Fired only when the transcript is not consumed by a local semantic
    /// intent. Normal requests continue through TRAVISAppState/orchestrator.
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

        // Meaning-based routing. The LLM is used only to understand intent;
        // it never performs the destructive action itself.
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

    /// Returns true when a local app action consumed the transcript.
    ///
    /// For now the first local semantic action is chat-history deletion.
    /// More local actions can be added to the same schema without teaching
    /// the user command phrases.
    private func consumeLocalSemanticIntent(_ transcript: String) async -> Bool {
        let prompt = """
        You are the semantic command router for TRAVIS, a personal AI assistant.

        Understand the USER'S MEANING, not keywords or exact phrases.
        The user may speak Greek, English, mixed language, slang, pronouns, or elliptical phrases.

        USER TRANSCRIPT:
        \(transcript)

        Classify whether the user intends a LOCAL CHAT-HISTORY ACTION.

        Supported local intent right now:
        - delete_conversation: the user wants to remove/delete/erase a conversation or chat from TRAVIS history.
        - none: anything else.

        Examples that all mean delete_conversation:
        - "σβήσε την τελευταία συνομιλία"
        - "αυτή τη συζήτηση δεν τη θέλω, πέταξέ την"
        - "βγάλε την προηγούμενη κουβέντα από το ιστορικό"
        - "delete that chat"
        - "καθάρισε αυτή τη συνομιλία"

        target values:
        - latest: latest previous conversation
        - viewed: conversation the user is currently viewing / deictic references like "αυτή"
        - unspecified: delete intent is clear but the target is not safely resolvable
        - null for intent none

        Safety rule:
        If deletion intent itself is uncertain, return none.
        If deletion intent is clear but which conversation is ambiguous, return
        delete_conversation with target "unspecified" and needsClarification true.

        Return ONLY valid JSON, no markdown:
        {
          "intent": "delete_conversation|none",
          "confidence": 0.0,
          "target": "latest|viewed|unspecified|null",
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

            guard parsed.intent == "delete_conversation", parsed.confidence >= 0.72 else {
                return false
            }

            if parsed.needsClarification || parsed.target == "unspecified" {
                // Do not risk deleting the wrong conversation. Pass a natural
                // clarification request through the normal assistant path.
                onFinalTranscript?("Θέλω να διαγράψω μια συνομιλία, αλλά δεν είναι σαφές ποια. Ρώτησέ με ποια συνομιλία εννοώ πριν διαγράψεις οτιδήποτε.")
                return true
            }

            // Existing ChatView owns the deterministic persistence delete.
            // The semantic target is attached for future target-aware UI
            // routing; current behavior deletes the most recent previous chat.
            NotificationCenter.default.post(
                name: Self.deleteLatestConversationNotification,
                object: parsed.target ?? "latest"
            )
            return true

        } catch {
            // AI intent routing failure must never block normal voice use.
            // Fall back to the existing orchestrator path.
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
