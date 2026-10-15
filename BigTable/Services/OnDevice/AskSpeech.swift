import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
import OSLog
import Speech

// Talking with Ask BigTable, hands free: the microphone and BigTable's voice share one audio
// engine with Apple's voice processing on, so echo cancellation removes BigTable's own voice
// from what the microphone hears and you can talk over it. Speech is recognized on the device
// with SpeechAnalyzer; replies are spoken with Apple's speech synthesizer.

// MARK: - Audio session

/// Every change to the shared audio session goes through one serial queue, off the main thread
/// (activating blocks), so a late "deactivate" can never land after the next "activate".
nonisolated enum AskAudioSession {
    private static let queue = DispatchQueue(label: "com.stephenwarren.bigtable.ask-audio")

    /// The microphone and the spoken replies at once, through voice processing. Speaker by
    /// default, so the conversation isn't stuck in the earpiece; headsets work too.
    static func activateForConversation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                    try session.setActive(true, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Hands audio back to other apps (and brings their music back up).
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

nonisolated enum AskVoiceError: Error {
    case noMicrophone
    case unsupportedLanguage
}

// MARK: - Audio thread helpers

/// Where microphone audio goes. Called on the audio thread.
nonisolated final class AskMicrophoneTap: @unchecked Sendable {
    private let sink = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    func setSink(_ new: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        sink.withLock { $0 = new }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        sink.withLock { $0 }?(buffer)
    }

    /// (Re)installs the tap in the microphone's current format. False when there's no
    /// microphone input (installing a tap then would crash).
    static func install(on input: AVAudioInputNode, tap: AskMicrophoneTap) -> Bool {
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tap.deliver(buffer)
        }
        return true
    }
}

/// Converts audio buffers to one format (sample rate, channels, sample type). Used from one
/// thread at a time.
nonisolated final class AskPCMConverter: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // The input block is @Sendable, so "fed" lives in a lock rather than a captured var.
        let fed = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let alreadyFed = fed.withLock { value -> Bool in
                let was = value
                value = true
                return was
            }
            if alreadyFed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Feeds microphone audio to the speech analyzer (converted to its format) and reports how
/// loud it is, on the audio thread.
nonisolated final class AskMicrophoneFeed: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AskPCMConverter
    private let onLevel: @Sendable (Double) -> Void
    private let muted = OSAllocatedUnfairLock(initialState: false)
    private let lastLevel = OSAllocatedUnfairLock(initialState: Date.distantPast)

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, converter: AskPCMConverter, onLevel: @escaping @Sendable (Double) -> Void) {
        self.continuation = continuation
        self.converter = converter
        self.onLevel = onLevel
    }

    func setMuted(_ value: Bool) {
        muted.withLock { $0 = value }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        guard !muted.withLock({ $0 }) else { return }
        reportLevel(buffer)
        if let converted = converter.convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() {
        continuation.finish()
    }

    /// About 20 times a second: the buffer's loudness, 0...1.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = Date.now
        let due = lastLevel.withLock { last -> Bool in
            guard now.timeIntervalSince(last) > 0.05 else { return false }
            last = now
            return true
        }
        guard due, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        onLevel(min(Double(sqrt(sum / Float(count))) * 12, 1))
    }
}

// MARK: - Audio engine

/// The microphone and BigTable's voice on one engine with voice processing (echo cancellation
/// and noise suppression), for the hands-free voice screen.
final class AskAudio {
    static let shared = AskAudio()

    /// The format BigTable's voice plays in; the synthesizer's audio is converted to it.
    static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!

    let player = AVAudioPlayerNode()
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let tap = AskMicrophoneTap()
    private var attached = false
    private var configurationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "ask-audio")

    private init() {
        // Switching to two-way voice reconfigures the hardware a moment after the engine
        // starts, which stops the engine. Start it again instead of going deaf.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    /// Opens the microphone (its audio goes to `sink`, on the audio thread) and the speaker.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        tap.setSink(sink)
        guard !isRunning else { return }
        try await AskAudioSession.activateForConversation()
        do {
            try startEngine()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            AskAudioSession.deactivate()
            throw error
        }
        isRunning = true
    }

    private func startEngine() throws {
        let input = engine.inputNode
        #if !targetEnvironment(simulator)
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
            attached = true
        }
        guard AskMicrophoneTap.install(on: input, tap: tap) else { throw AskVoiceError.noMicrophone }
        engine.prepare()
        try engine.start()
    }

    /// After the hardware changed: the tap again (the format may have changed) and the engine.
    private func restart() {
        guard isRunning else { return }
        log.notice("Restarting the microphone after an audio configuration change")
        guard AskMicrophoneTap.install(on: engine.inputNode, tap: tap) else { return }
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Plays the voice player (only while the engine runs; playing a node otherwise crashes).
    func playVoice() -> Bool {
        guard isRunning, engine.isRunning else { return false }
        player.play()
        return true
    }

    func stop() {
        tap.setSink(nil)
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if !targetEnvironment(simulator)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #endif
        isRunning = false
        AskAudioSession.deactivate()
    }
}

// MARK: - Speaking

/// Speaks Ask BigTable's replies with Apple's speech synthesizer, through the voice screen's
/// audio engine (so echo cancellation knows what BigTable is saying).
@Observable
final class AskSpeaker {
    static let shared = AskSpeaker()

    private(set) var isSpeaking = false
    /// What's being said, to tell BigTable's own voice apart from the person's.
    private(set) var spokenText = ""

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let converter = AskPCMConverter(target: AskAudio.playbackFormat)
    /// Bumped by every speak and stop, so callbacks from an earlier reply are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingBuffers = 0
    @ObservationIgnored private var producing = false
    /// Runs once when the reply has finished playing (not when it's stopped).
    @ObservationIgnored private var onFinished: (() -> Void)?

    /// Speaks `text`; `onFinished` runs when it has all played.
    func speak(_ text: String, onFinished: @escaping () -> Void) {
        stop()
        let spoken = AskText.clean(text)
        guard !spoken.isEmpty, AskAudio.shared.playVoice() else {
            onFinished()
            return
        }
        let current = generation
        self.onFinished = onFinished
        spokenText = spoken
        isSpeaking = true
        producing = true
        pendingBuffers = 0
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.bestVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        Self.write(utterance, with: synthesizer) { [weak self] buffer in
            let speaker = self
            Task { @MainActor in speaker?.received(buffer, generation: current) }
        }
    }

    func stop() {
        generation += 1
        onFinished = nil
        producing = false
        pendingBuffers = 0
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if AskAudio.shared.isRunning { AskAudio.shared.player.stop() }
        isSpeaking = false
        spokenText = ""
    }

    /// A buffer of speech (nil at the end), converted and queued on the player.
    private func received(_ buffer: AVAudioPCMBuffer?, generation current: Int) {
        guard current == generation else { return }
        guard let buffer else {
            producing = false
            if pendingBuffers == 0 { finished() }
            return
        }
        guard AskAudio.shared.isRunning, let converted = converter.convert(buffer) else { return }
        pendingBuffers += 1
        Self.schedule(converted, on: AskAudio.shared.player) { [weak self] in
            let speaker = self
            Task { @MainActor in speaker?.played(generation: current) }
        }
    }

    private func played(generation current: Int) {
        guard current == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        if pendingBuffers == 0, !producing { finished() }
    }

    private func finished() {
        isSpeaking = false
        spokenText = ""
        let done = onFinished
        onFinished = nil
        done?()
    }

    // The synthesizer and player call back on their own threads, so the callbacks are made
    // outside the main actor and hop back to it themselves.

    private nonisolated static func write(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer, deliver: @escaping @Sendable (AVAudioPCMBuffer?) -> Void) {
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            deliver(pcm.frameLength == 0 ? nil : pcm)
        }
    }

    private nonisolated static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode, done: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    /// The best-sounding voice for the person's language: Premium, then Enhanced, then default.
    static var bestVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let ranked = voices.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return (lhs.language == preferred ? 1 : 0) > (rhs.language == preferred ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: preferred)
    }
}

// MARK: - The conversation

/// A spoken conversation with Ask BigTable, hands free.
///
/// The microphone stays open. When you stop talking for a moment (about 1.2 seconds), what you
/// said goes to BigTable, which answers out loud and then listens again. Start talking while
/// it's thinking or speaking and it stops to listen. Every exchange is also added to the Ask
/// conversation, with its cards.
@Observable
final class AskConversation {
    enum Phase: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        /// The microphone is turned off (the mic button).
        case micOff
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// What you're saying now.
    private(set) var transcript = ""
    /// Your last finished question.
    private(set) var question = ""
    /// BigTable's latest reply (or the notice it gave instead).
    private(set) var replyID: UUID?
    /// Microphone loudness, 0...1.
    private(set) var level: Double = 0
    private(set) var isMuted = false

    /// How long a silence ends your turn.
    static let pause: TimeInterval = 1.2
    /// After this long with nothing said, the microphone turns off.
    static let idleLimit: TimeInterval = 90

    @ObservationIgnored private var engine: AskEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AskMicrophoneFeed?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// Bumped for every question (and on interruptions), so a stale answer isn't spoken.
    @ObservationIgnored private var exchange = 0
    /// Finished words of the current turn, and the words still being recognized.
    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var volatile = ""
    /// Audio before this belongs to earlier turns; late results for it are ignored.
    @ObservationIgnored private var consumedUntil = CMTime.zero
    /// The end of the latest result heard.
    @ObservationIgnored private var latestEnd = CMTime.zero
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private let audio = AskAudio.shared
    @ObservationIgnored private let speaker = AskSpeaker.shared
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.bigtable", category: "ask-voice")

    var isListening: Bool { phase == .listening && !isMuted }

    func start(with engine: AskEngine) async {
        self.engine = engine
        stopListening()
        phase = .starting
        guard await Self.permissionsGranted() else {
            phase = .failed(AskVoiceText.denied)
            return
        }
        do {
            try await startListening()
        } catch {
            log.error("Couldn't start listening: \(String(describing: error), privacy: .public)")
            stopListening()
            phase = .failed(AskVoiceText.unavailable)
            return
        }
        isMuted = false
        clearTurn()
        lastHeard = .now
        phase = .listening
        watch()
    }

    /// Ends the conversation: microphone off, BigTable quiet.
    func stop() {
        exchange += 1
        stopListening()
        if case .failed = phase { return }
        phase = .micOff
    }

    /// The mic button: stop or start hearing you (BigTable can still finish talking).
    func setMuted(_ muted: Bool) {
        isMuted = muted
        feed?.setMuted(muted)
        if muted {
            clearTurn()
            level = 0
            if phase == .listening { phase = .micOff }
        } else {
            lastHeard = .now
            if phase == .micOff { phase = .listening }
        }
    }

    /// The big circle: send now while listening, stop BigTable while it talks or thinks, or
    /// turn the microphone back on.
    func tapOrb() {
        if isMuted {
            setMuted(false)
            return
        }
        switch phase {
        case .listening:
            if !transcript.isEmpty { endTurn() }
        case .speaking, .thinking:
            interrupt()
        case .failed:
            if let engine { Task { await self.start(with: engine) } }
        case .starting, .micOff:
            break
        }
    }

    // MARK: Listening

    private func startListening() async throws {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = supported else { throw AskVoiceError.unsupportedLanguage }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // The speech model downloads the first time it's used for a language.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AskVoiceError.unsupportedLanguage
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = AskMicrophoneFeed(continuation: continuation, converter: AskPCMConverter(target: format)) { [weak self] value in
            let conversation = self
            Task { @MainActor in conversation?.levelChanged(value) }
        }
        self.analyzer = analyzer
        self.feed = feed
        consumedUntil = .zero
        latestEnd = .zero

        try await analyzer.start(inputSequence: stream)
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.heard(String(result.text.characters), isFinal: result.isFinal, range: result.range)
                }
            } catch {
                self?.log.notice("Speech results ended: \(String(describing: error), privacy: .public)")
            }
        }
        try await audio.start { buffer in feed.handle(buffer) }
    }

    private func stopListening() {
        watcher?.cancel()
        watcher = nil
        speaker.stop()
        audio.stop()
        feed?.finish()
        feed = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        level = 0
    }

    private func levelChanged(_ value: Double) {
        guard !isMuted else { return }
        level = value
    }

    private func clearTurn() {
        transcript = ""
        settled = ""
        volatile = ""
        consumedUntil = latestEnd
    }

    private func heard(_ text: String, isFinal: Bool, range: CMTimeRange) {
        // Late results for words from an earlier turn (it already went to BigTable).
        guard CMTimeCompare(range.start, consumedUntil) >= 0 else { return }
        let end = CMTimeRangeGetEnd(range)
        if CMTimeCompare(end, latestEnd) > 0 { latestEnd = end }

        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            settled = Self.join(settled, words)
            volatile = ""
        } else {
            volatile = words
        }
        let combined = Self.join(settled, volatile)
        guard !combined.isEmpty, combined != transcript else { return }

        switch phase {
        case .listening:
            guard !isMuted else { return }
            transcript = combined
            lastHeard = .now
        case .thinking, .speaking:
            if isEcho(combined) {
                // BigTable's own voice leaking past echo cancellation: not you.
                settled = ""
                volatile = ""
            } else if AskText.words(combined).count >= 2 {
                interrupt()
                transcript = combined
                lastHeard = .now
            }
        case .starting, .micOff, .failed:
            break
        }
    }

    /// Checks for the end of your turn.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .listening, !isMuted else { return }
        let quiet = Date.now.timeIntervalSince(lastHeard)
        if transcript.isEmpty {
            if quiet >= Self.idleLimit { setMuted(true) }
            return
        }
        // Still making sound mid-word: not a pause yet.
        if level > 0.35 {
            lastHeard = .now
            return
        }
        if quiet >= Self.pause { endTurn() }
    }

    // MARK: Turns

    private func endTurn() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine else { return }
        question = text
        clearTurn()
        exchange += 1
        let current = exchange
        phase = .thinking
        replyID = nil
        let previous = sending
        sending = Task { [weak self] in
            // One question at a time.
            await previous?.value
            guard let self, current == self.exchange else { return }
            let before = engine.messages.count
            await engine.send(text)
            guard current == self.exchange else { return }
            self.answered(engine.messages.dropFirst(before).last(where: { $0.role != .user }), exchange: current)
        }
    }

    private func answered(_ reply: AskMessage?, exchange current: Int) {
        guard let reply else {
            backToListening(clearing: true)
            return
        }
        replyID = reply.id
        let text = reply.text.isEmpty ? "Done." : reply.text
        phase = .speaking
        speaker.speak(text) { [weak self] in
            guard let self, current == self.exchange, self.phase == .speaking else { return }
            self.backToListening(clearing: true)
        }
    }

    /// Listens for the next question. `clearing` drops anything half-heard while BigTable
    /// talked (stray words, or its own voice).
    private func backToListening(clearing: Bool) {
        if clearing { clearTurn() }
        lastHeard = .now
        phase = isMuted ? .micOff : .listening
    }

    /// You started talking (or tapped) while BigTable was thinking or speaking.
    private func interrupt() {
        exchange += 1
        speaker.stop()
        backToListening(clearing: false)
    }

    /// Words heard while BigTable talks that are all in what it's saying.
    private func isEcho(_ text: String) -> Bool {
        guard phase == .speaking, !speaker.spokenText.isEmpty else { return false }
        let said = Set(AskText.words(speaker.spokenText))
        return AskText.words(text).allSatisfy { said.contains($0) }
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    // MARK: Permissions

    private nonisolated static func permissionsGranted() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case let status:
            speech = status
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// What the voice screen says when it can't listen.
enum AskVoiceText {
    static let denied = "BigTable needs microphone and speech recognition access to listen. Turn them on in Settings › BigTable."
    static let unavailable = "BigTable couldn’t start listening. Check that the microphone isn’t in use, then try again."
}
