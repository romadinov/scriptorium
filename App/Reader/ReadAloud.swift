import AVFoundation
import MediaPlayer
import Observation
import os
import ReaderCore

private let log = Logger(subsystem: "com.romadinov.reader", category: "ReadAloud")

/// Reads the book aloud with AVSpeechSynthesizer, one paragraph-sized chunk at a time.
/// The viewer supplies text (`ReaderModel.speechParagraphs`) and shows what is being spoken
/// (`ReaderModel.speechHighlight`); this class owns the voice, speed and playback state.
@MainActor @Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    enum State { case idle, playing, paused }

    private(set) var state: State = .idle {
        didSet { if (state == .idle) != (oldValue == .idle) { model?.readingAloudChanged?(state != .idle) } }
    }
    /// 0.5…2 × normal speed.
    var speed: Double = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(speed, forKey: "speechSpeed") }
    }
    /// A specific voice, or nil to pick the best installed voice for each paragraph's language.
    var voiceID: String? = UserDefaults.standard.string(forKey: "speechVoice") {
        didSet { UserDefaults.standard.set(voiceID, forKey: "speechVoice") }
    }
    private(set) var language: String?
    /// Start of the passage being spoken (for VoiceOver and tests).
    private(set) var nowReading = ""

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private weak var model: ReaderModel?
    @ObservationIgnored private var queue: [SpeechPlanner.Chunk] = []
    @ObservationIgnored private var current: SpeechPlanner.Chunk?
    @ObservationIgnored private var lastSentence = NSRange(location: NSNotFound, length: 0)
    @ObservationIgnored private var selectionOnly = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private var startAt: (anchor: Int, offset: Int)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var rate: Float {
        // AVSpeechUtterance's 0.5 is normal; the scale is not linear, this mapping sounds natural.
        let scaled = Float(0.5 + (speed - 1) * 0.18)
        return min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    // MARK: Control

    /// Starts reading the selection if there is one, else from the current position onward
    /// (or from `from`: a word the reader tapped — anchor and UTF-16 offset as in `speechParagraphs`).
    func start(_ model: ReaderModel, from: (anchor: Int, offset: Int)? = nil) {
        stop()
        self.model = model
        generation += 1
        activateAudio(title: model.book.title)
        state = .playing
        startAt = from
        if from == nil, !model.selection.isEmpty {
            selectionOnly = true
            queue = SpeechPlanner.chunks([(model.selection, -1)])
            speakNext()
        } else {
            selectionOnly = false
            let gen = generation
            Task {
                await refill(restart: true)
                guard gen == generation else { return }
                speakNext()
            }
        }
    }

    func toggle() {
        switch state {
        case .playing:
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            synthesizer.continueSpeaking()
            state = .playing
        case .idle:
            if let model { start(model) }
        }
        updateNowPlaying()
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        queue = []
        current = nil
        if state != .idle { model?.speechHighlight?(-1, nil) }
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Queue

    private func refill(restart: Bool) async {
        guard let model, let source = model.speechParagraphs else { return }
        // Reflowable books load the next chapter on demand; give it a moment before calling it the end.
        for attempt in 0..<6 {
            let batch = await source(restart && attempt == 0)
            let chunks = SpeechPlanner.chunks(batch, startingAt: restart ? startAt : nil)
            log.debug("refill restart=\(restart) attempt=\(attempt): \(batch.count) paragraphs → \(chunks.count) chunks")
            if !chunks.isEmpty {
                if restart { startAt = nil }
                queue += chunks
                return
            }
            if batch.isEmpty, attempt < 5 { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    private func speakNext() {
        guard state != .idle else { return }
        if queue.isEmpty {
            guard !selectionOnly else { return stop() }
            let gen = generation
            Task {
                await refill(restart: false)
                guard gen == generation else { return }
                if queue.isEmpty { stop() } else { speakNext() }
            }
            return
        }
        let chunk = queue.removeFirst()
        current = chunk
        lastSentence = NSRange(location: NSNotFound, length: 0)
        language = chunk.language
        nowReading = String(chunk.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        let utterance = AVSpeechUtterance(string: chunk.text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? SpeechPlanner.bestVoice(for: chunk.language)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.15
        log.debug("speak anchor=\(chunk.anchor) lang=\(chunk.language ?? "nil", privacy: .public) voice=\(utterance.voice?.identifier ?? "nil", privacy: .public) text=\(String(chunk.text.prefix(40)), privacy: .public)")
        synthesizer.speak(utterance)
        updateNowPlaying()
    }

    // MARK: AVSpeechSynthesizerDelegate

    /// Highlight the first sentence as soon as a chunk starts: some voices never report word ranges,
    /// and the page must still follow the narration.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let chunk = self.current, chunk.anchor >= 0, self.lastSentence.location == NSNotFound else { return }
            let first = SpeechPlanner.sentence(containing: NSRange(location: 0, length: 0), in: chunk.text)
            self.lastSentence = first
            self.model?.speechHighlight?(chunk.anchor, NSRange(location: chunk.offset + first.location, length: first.length))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        log.debug("didFinish")
        Task { @MainActor in self.speakNext() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let chunk = self.current, chunk.anchor >= 0 else { return }
            let sentence = SpeechPlanner.sentence(containing: range, in: chunk.text)
            guard sentence != self.lastSentence else { return }
            self.lastSentence = sentence
            self.model?.speechHighlight?(chunk.anchor, NSRange(location: chunk.offset + sentence.location, length: sentence.length))
        }
    }

    // MARK: Audio session & lock screen

    private func activateAudio(title: String) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.state == .paused { self?.toggle() } }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.state == .playing { self?.toggle() } }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let model else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: model.book.title,
            MPMediaItemPropertyArtist: "Scriptorium · \(model.currentPosition.label)",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
    }

    /// Voices for the language being read (for the voice menu), best first.
    var voicesForCurrentLanguage: [AVSpeechSynthesisVoice] {
        let base = String((language ?? Locale.current.language.languageCode?.identifier ?? "en").prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}
