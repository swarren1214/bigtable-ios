import AVFoundation
import Foundation
import Observation

/// Why a recording couldn't start.
nonisolated struct RecipeAudioError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }

    static let microphoneDenied = RecipeAudioError(message: "BigTable needs the microphone to record your recipe. Turn it on in Settings › BigTable.")
    static let couldNotStart = RecipeAudioError(message: "Recording couldn't start. Try again in a moment.")
    static let empty = RecipeAudioError(message: "The recording is empty. Record it again.")
}

/// Records a spoken recipe as an .m4a (AAC) file for Create with AI, with a live level meter
/// for the waveform, as the Expo app's voice note did.
@MainActor
@Observable
final class RecipeAudioRecorder {
    enum State: Equatable {
        case idle
        case recording
        case recorded
    }

    private(set) var state: State = .idle
    /// Seconds recorded.
    private(set) var duration: TimeInterval = 0
    /// Recent levels, 0…1, for the waveform.
    private(set) var levels: [Double] = []

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    private static let silenceDB: Float = -48
    private static let peakDB: Float = -6
    private static let maxLevels = 600

    func start() async throws {
        guard state != .recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecipeAudioError.microphoneDenied }
        discard()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appending(path: "recipe-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecipeAudioError.couldNotStart
        }
        self.recorder = recorder
        fileURL = url
        duration = 0
        levels = []
        state = .recording

        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                self.sample()
            }
        }
    }

    func stop() {
        guard state == .recording, let recorder else { return }
        meterTask?.cancel()
        meterTask = nil
        duration = max(duration, recorder.currentTime)
        recorder.stop()
        self.recorder = nil
        state = .recorded
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Throws the recording away.
    func discard() {
        if state == .recording {
            meterTask?.cancel()
            meterTask = nil
            recorder?.stop()
            recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        duration = 0
        levels = []
        state = .idle
    }

    /// The finished recording's bytes.
    func audioData() throws -> Data {
        guard state == .recorded, let fileURL else { throw RecipeAudioError.empty }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw RecipeAudioError.empty }
        return data
    }

    private func sample() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        duration = recorder.currentTime
        let power = recorder.averagePower(forChannel: 0)
        let gated = min(Self.peakDB, max(Self.silenceDB, power))
        let normalized = Double((gated - Self.silenceDB) / (Self.peakDB - Self.silenceDB))
        levels.append(pow(normalized, 1.65))
        if levels.count > Self.maxLevels {
            levels.removeFirst(levels.count - Self.maxLevels)
        }
    }

    /// "0:42".
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
