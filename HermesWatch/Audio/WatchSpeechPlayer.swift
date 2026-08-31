import AVFoundation
import Foundation
import Observation
import OSLog

/// Plays synthesized speech clips back-to-back on Apple Watch, per
/// WATCHOS_ARCHITECTURE_SPEC §3.1 "Audio Output."
///
/// ### Deliberate correction to WATCHOS_ARCHITECTURE_SPEC §3.1
/// The spec calls for "Immediate playback of streaming TTS audio chunks
/// received from Hermes" — i.e. a chunked audio stream the client plays as it
/// arrives. The server does not offer that: `POST /api/tts` takes
/// `{text, voice}` and returns a single, fully buffered `audio/mpeg` payload
/// with a real `Content-Length` (not `Transfer-Encoding: chunked`), verified
/// by reading `hermes-webui`'s route source (AGENTS.md rule 1). There is no
/// per-chunk audio frame to play as it arrives.
///
/// The corrected architecture: the chat view model segments the assistant's
/// *text* into complete sentences as they stream in (`splitCompleteSentences`
/// below), fires one `POST /api/tts` call per sentence, and `enqueue`s each
/// resulting MP3 clip here as soon as it's synthesized. This player then
/// plays the queue back-to-back with `AVAudioPlayer`, so the user hears
/// speech begin after the *first sentence* finishes synthesizing rather than
/// waiting for the whole reply — an approximation of streaming built entirely
/// out of complete, independently synthesizable units.
@MainActor
@Observable
final class WatchSpeechPlayer: NSObject {
    /// Mirrors `ServerTTSPolicy.defaultVoice` in the iOS `ChatViewModel.swift`
    /// (not compiled into the watch target — that file is SwiftUI/iOS-only,
    /// wired to `ComposerVoiceInputController` and other iPhone-only chat UI).
    /// The server's own default voice is `zh-CN-XiaoxiaoNeural`, so callers on
    /// the watch must always pass a voice explicitly to `/api/tts` rather than
    /// omitting it and hoping for an English default.
    static let defaultVoice = "en-US-AriaNeural"

    /// Upper bound on queued-but-not-yet-played clips. A runaway reply (or a
    /// stuck player) must not let the queue grow without bound and exhaust
    /// watch memory; beyond this we drop the oldest still-queued clip.
    private static let maximumQueuedClips = 24

    /// Level meter poll rate while a clip is playing. `nonisolated` so the
    /// polling `Task {}` below can read it before its first `await`.
    nonisolated private static let levelPollHz: Double = 15

    private(set) var isPlaying = false
    /// Smoothed 0...1 output level for the speaking orb, derived from
    /// `AVAudioPlayer.averagePower(forChannel:)`.
    private(set) var level: Float = 0

    /// Called once the queue is fully drained and playback stops naturally
    /// (not on `stop()`), so the caller can transition `WatchVoiceState` back
    /// to `.idle`.
    var onFinishedAll: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile.watchkitapp", category: "WatchSpeechPlayer")

    private var queue: [Data] = []
    private var currentPlayer: AVAudioPlayer?
    private var levelPollTask: Task<Void, Never>?
    private var didActivateSession = false

    /// Appends one already-synthesized MP3 clip (one sentence, per §3.1's
    /// corrected sentence-at-a-time model above) to the playback queue. If
    /// nothing is currently playing, starts immediately.
    func enqueue(_ mp3: Data) {
        guard !mp3.isEmpty else { return }

        if queue.count >= Self.maximumQueuedClips {
            logger.warning("Speech queue at capacity (\(Self.maximumQueuedClips, privacy: .public)); dropping oldest clip.")
            queue.removeFirst()
        }
        queue.append(mp3)

        if !isPlaying {
            playNext()
        }
    }

    /// Stops playback immediately and discards the queue. Does not invoke
    /// `onFinishedAll` — that callback is reserved for a queue that drained
    /// naturally, not one the caller cut off (e.g. the user interrupted with
    /// a new recording).
    func stop() {
        levelPollTask?.cancel()
        levelPollTask = nil
        currentPlayer?.stop()
        currentPlayer = nil
        queue.removeAll()
        isPlaying = false
        level = 0
        deactivateSession()
    }

    // MARK: - Playback

    private func playNext() {
        guard !queue.isEmpty else {
            isPlaying = false
            level = 0
            deactivateSession()
            onFinishedAll?()
            return
        }

        let clip = queue.removeFirst()

        if !didActivateSession {
            guard activateSessionForPlayback() else {
                // No route available (e.g. Series 3 without paired
                // Bluetooth audio in some configurations) — per the task
                // brief, surface this as a silent no-op rather than a
                // crash: drop the remaining queue and report "finished"
                // so the caller's voice state doesn't get stuck in
                // `.speaking` forever.
                logger.error("No audio route available for playback; dropping speech queue.")
                queue.removeAll()
                isPlaying = false
                level = 0
                onFinishedAll?()
                return
            }
        }

        do {
            let player = try AVAudioPlayer(data: clip)
            player.delegate = self
            player.isMeteringEnabled = true
            guard player.play() else {
                logger.error("AVAudioPlayer.play() returned false; skipping clip.")
                playNext()
                return
            }
            currentPlayer = player
            isPlaying = true
            startLevelPolling()
        } catch {
            logger.error("Failed to decode a queued speech clip: \(String(describing: error), privacy: .public); skipping.")
            playNext()
        }
    }

    /// Configures the session for playback before the first clip: `.playback`
    /// category with `.spokenAudio` mode, per the task brief. Returns `false`
    /// (rather than throwing) if the session can't be activated, so the
    /// no-route case above can degrade gracefully.
    private func activateSessionForPlayback() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
            didActivateSession = true
            return true
        } catch {
            logger.error("Failed to activate playback session: \(String(describing: error), privacy: .public)")
            didActivateSession = false
            return false
        }
    }

    private func deactivateSession() {
        guard didActivateSession else { return }
        // Matches `WatchAudioEngine.teardownAndDeactivate`: hand the session
        // back and let anything we interrupted resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        didActivateSession = false
    }

    // MARK: - Level metering

    private func startLevelPolling() {
        levelPollTask?.cancel()
        levelPollTask = Task { [weak self] in
            let intervalNanoseconds = UInt64(1_000_000_000 / Self.levelPollHz)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.pollLevel()
                }
            }
        }
    }

    private func pollLevel() {
        guard let currentPlayer, currentPlayer.isPlaying else { return }
        currentPlayer.updateMeters()
        let decibels = currentPlayer.averagePower(forChannel: 0)
        // Map -60...0 dB to 0...1, clamping outside that range. -60 dB is a
        // conventional "silence floor" for a meter like this.
        let normalized = (decibels + 60) / 60
        let clamped = min(max(normalized, 0), 1)
        let smoothing: Float = 0.3
        level = level + smoothing * (clamped - level)
    }

    // MARK: - Sentence segmentation

    /// Splits `buffer` into complete sentences plus a trailing incomplete
    /// remainder, so a chat view model can call this on each streamed text
    /// delta and synthesize+enqueue only the parts that are done. A sentence
    /// is considered complete when it ends in `.`, `!`, `?`, or `\n` followed
    /// by whitespace or the end of the checked prefix. Each returned sentence
    /// is trimmed of leading/trailing whitespace; the whitespace run right
    /// after a terminator is consumed into the split point (not left as a
    /// leading space on the next sentence or the remainder).
    ///
    /// - Empty input returns `(sentences: [], remainder: "")`.
    /// - Input with no terminator returns `(sentences: [], remainder: buffer)`
    ///   verbatim (not trimmed — it's still-accumulating raw text, not a
    ///   finished sentence), so the caller keeps accumulating until a
    ///   terminator (or the stream ends) appears.
    /// - Trailing whitespace after the final terminator is consumed into the
    ///   split point, not left dangling in the remainder.
    static func splitCompleteSentences(_ buffer: String) -> (sentences: [String], remainder: String) {
        guard !buffer.isEmpty else { return ([], "") }

        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var sentences: [String] = []
        var sentenceStart = buffer.startIndex
        var index = buffer.startIndex

        while index < buffer.endIndex {
            let character = buffer[index]
            let nextIndex = buffer.index(after: index)

            if terminators.contains(character) {
                // A `.`/`!`/`?` only ends a sentence if it's followed by
                // whitespace or the end of the buffer — this avoids splitting
                // on things like "3.14" or "e.g." mid-token where the next
                // character is not a space. (Not a perfect abbreviation
                // detector; a pragmatic heuristic.)
                //
                // A newline is different: it IS the boundary, so it never
                // needs a following whitespace character. Without this case,
                // "Line one\nLine two" would not split — and agent replies are
                // full of newline-delimited lists that would then stay silent
                // until the whole run finished.
                let isFollowedByBoundary = character == "\n"
                    || nextIndex == buffer.endIndex
                    || buffer[nextIndex].isWhitespace

                if isFollowedByBoundary {
                    let sentence = buffer[sentenceStart..<nextIndex]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty {
                        sentences.append(sentence)
                    }
                    // Skip any run of whitespace after the terminator so the
                    // next sentence's start doesn't carry a leading space.
                    var afterTerminator = nextIndex
                    while afterTerminator < buffer.endIndex, buffer[afterTerminator].isWhitespace {
                        afterTerminator = buffer.index(after: afterTerminator)
                    }
                    sentenceStart = afterTerminator
                    index = afterTerminator
                    continue
                }
            }

            index = nextIndex
        }

        let remainder = String(buffer[sentenceStart...])
        return (sentences, remainder)
    }
}

// MARK: - AVAudioPlayerDelegate

extension WatchSpeechPlayer: AVAudioPlayerDelegate {
    /// `AVAudioPlayerDelegate` callbacks are `nonisolated` (the protocol
    /// itself is not actor-bound), so this hops back to the main actor
    /// before touching any observable state or advancing the queue.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.handleFinishedPlaying(player, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.logger.error("Speech clip decode error: \(String(describing: error), privacy: .public)")
            self.handleFinishedPlaying(player, successfully: false)
        }
    }

    private func handleFinishedPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Ignore callbacks from a player we've already discarded (e.g. a
        // `stop()` raced with a finish callback in flight).
        guard player === currentPlayer else { return }

        if !flag {
            logger.warning("A speech clip finished unsuccessfully; continuing with the queue.")
        }

        levelPollTask?.cancel()
        levelPollTask = nil
        currentPlayer = nil
        playNext()
    }
}
