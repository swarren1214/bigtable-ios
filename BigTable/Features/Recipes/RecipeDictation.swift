import AVFoundation
import Foundation
import Observation
import Speech

/// Why dictation couldn't start.
nonisolated struct RecipeDictationError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }

    static let unavailable = RecipeDictationError(message: "Dictation isn't available right now. You can type the recipe instead.")
    static let speechDenied = RecipeDictationError(message: "BigTable needs speech recognition to turn what you say into text. Turn it on in Settings › BigTable.")
    static let microphoneDenied = RecipeDictationError(message: "BigTable needs the microphone for dictation. Turn it on in Settings › BigTable.")
}

/// Turns what you say into text on the device (Apple's speech recognizer, on-device when the
/// phone supports it), for Create with AI's description. It takes the place of the Expo app's
/// on-device Whisper transcription: the words become a transcript that's sent to
/// /v1/bigtable/ai/recipe-transcript rather than sending the audio itself.
@MainActor
@Observable
final class RecipeDictation {
    private(set) var isListening = false
    /// What's been heard so far in this session.
    private(set) var transcript = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() async throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else { throw RecipeDictationError.unavailable }
        guard await Self.requestSpeechAuthorization() == .authorized else { throw RecipeDictationError.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecipeDictationError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        do {
            try Self.installTap(on: engine, feeding: request)
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        self.engine = engine
        self.request = request
        transcript = ""
        isListening = true
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isDone in
            guard let self else { return }
            Task { @MainActor in
                self.receive(text: text, isDone: isDone)
            }
        }
    }

    /// Stops listening; the last words heard stay in `transcript`.
    func stop() {
        guard isListening else { return }
        isListening = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        task?.finish()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func receive(text: String?, isDone: Bool) {
        if let text, !text.isEmpty { transcript = text }
        if isDone { stop() }
    }

    // These run off the main actor: the audio tap and the recognizer call back on their own
    // queues.

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func installTap(on engine: AVAudioEngine, feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecipeDictationError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isDone = error != nil || (result?.isFinal ?? false)
            onUpdate(text, isDone)
        }
    }
}
