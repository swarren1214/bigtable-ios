import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

/// Turns a recorded voice note into text on the device with Apple's speech model
/// (SpeechAnalyzer), instead of uploading the audio for the API to send to Whisper. The model
/// downloads the first time it's used for a language. Returns nil when it can't, and the
/// caller uploads the recording as before.
nonisolated enum OnDeviceTranscriber {
    private static let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "OnDeviceTranscriber")

    @concurrent static func transcribe(_ audio: Data, fileExtension: String = "m4a") async -> String? {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcribe-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.write(to: url)
            guard await isAuthorized() else { return nil }
            var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
            guard let locale = supported else { return nil }

            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }

            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let text: String = transcriber.results.reduce(into: "") { text, result in
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segment.isEmpty else { return }
                text += text.isEmpty ? segment : " " + segment
            }
            // The results only end when the analyzer finishes, so finish it on every path.
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
            let transcript = try await text.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? nil : transcript
        } catch {
            log.notice("On-device transcription fell back to the API: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Speech recognition permission, asked for the first time it's needed.
    private static func isAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return status == .authorized
        default: return false
        }
    }
}
