import AVFoundation
import Foundation
import Observation
import OSLog

/// Records a short "Send Voice Note" clip to a temporary AAC `.m4a` file via
/// `AVAudioRecorder`, which watchOS supports directly (unlike `AVAudioEngine`
/// tap-based capture, which some watch hardware handles less reliably for a
/// simple record-to-disk use case).
///
/// ### Why this is a separate type from `WatchAudioEngine`
/// `WatchAudioEngine` exists for the voice-*chat* screen: it produces raw
/// 16 kHz mono PCM16 wrapped in a WAV header, matched exactly to what
/// `POST /api/transcribe` expects for a one-shot STT call, and nothing about
/// that clip is ever persisted or replayed. A voice *note*, in contrast, is
/// meant to be uploaded as a chat attachment and rendered by the inline audio
/// player on iOS/web — it must be a compact, standard, playable format (AAC in
/// an `.m4a` container), not a raw PCM dump. Sharing one type for both would
/// mean branching its entire output pipeline on which screen is using it; two
/// small, single-purpose recorders are easier to reason about and test.
///
/// ### Sample rate: 22.05 kHz, not the iOS composer's 44.1 kHz
/// `ComposerVoiceNoteRecorder` (iOS) records at 44.1 kHz because it runs on a
/// device with headroom to spare. A wrist mic captures speech, not music: there
/// is no content above ~8 kHz worth preserving, and the clip still has to cross
/// a Bluetooth-relayed Wi-Fi hop to the phone before it ever reaches the
/// server, then gets uploaded again from there. Recording at 22.05 kHz halves
/// the encoded bitrate for the same perceptual quality, keeps clips well under
/// `PendingAttachment.maximumUploadBytes`, and the server's STT model
/// transcribes it exactly as well as a 44.1 kHz clip of the same speech.
@MainActor
@Observable
final class WatchVoiceNoteRecorder {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
    }

    struct RecordedVoiceNote: Equatable {
        let data: Data
        let filename: String
        let duration: TimeInterval
    }

    /// Hard cap on a single note. Kept far shorter than the iOS composer's 5
    /// minutes: a voice note here is meant to be a quick dictation aside, not a
    /// long recording, and a shorter cap keeps the wrist screen's "recording…"
    /// affordance from feeling stuck open.
    static let maximumDuration: TimeInterval = 60
    /// Clips shorter than this are treated as an accidental tap and discarded.
    static let minimumDuration: TimeInterval = 0.5

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Smoothed 0...1 input level, for a listening/level UI. See
    /// `smoothedLevel(previous:dBFS:)` for how this is derived.
    private(set) var level: Float = 0
    private(set) var errorMessage: String?

    var isRecording: Bool { state == .recording }
    var hasReachedMaximumDuration: Bool { elapsed >= Self.maximumDuration }

    /// AAC mono at 22.05 kHz, `.medium` quality. Comfortably under 20 KB/s, so
    /// even a full 60s clip stays well under `PendingAttachment.maximumUploadBytes`
    /// (20 MB) with enormous headroom.
    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 22_050.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// `@ObservationIgnored` is load-bearing, not just an optimization: `deinit`
    /// is nonisolated and may only touch *stored* properties of a `@MainActor`
    /// type. Without it the `@Observable` macro rewrites these into computed
    /// properties, and the cleanup in `deinit` stops compiling. Matches
    /// `ComposerVoiceNoteRecorder.ticker` on iOS. Neither is UI state worth
    /// observing anyway — both are cancellation handles.
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var capTask: Task<Void, Never>?
    private var didActivateSession = false
    /// Set the moment the 60s cap fires, so `finish()` can report the known
    /// cap duration instead of reading `AVAudioRecorder.currentTime` — which
    /// resets to 0 once the recorder has been stopped (see `scheduleCap()`).
    private var didReachCapWhileRecording = false

    private let logger = Logger(
        subsystem: "com.uzairansar.hermesmobile.watchkitapp",
        category: "WatchVoiceNoteRecorder"
    )

    // MARK: - Lifecycle

    /// Requests mic permission (if needed), configures the audio session, and
    /// starts recording to a temporary `.m4a` file named by
    /// `VoiceNoteFilename.generate()`. No-op if already active.
    func begin() async {
        guard state == .idle else { return }
        errorMessage = nil
        elapsed = 0
        level = 0
        didReachCapWhileRecording = false
        state = .requestingPermission

        let granted = await requestPermission()
        // `state` can change while we await the system prompt (e.g. the view
        // disappeared and called `cancel()`); bail rather than starting late,
        // matching `ComposerVoiceNoteRecorder.begin()`'s same guard.
        guard state == .requestingPermission else { return }
        guard granted else {
            fail(String(localized: "Microphone access is disabled. Enable it in the Watch app on your iPhone."))
            return
        }

        do {
            try startRecording()
            state = .recording
            startTicker()
            scheduleCap()
            logger.info("Voice note recording started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Stops recording and returns the finished clip, or nil if it was too
    /// short, unreadable, or wasn't recording. Always tears down the audio
    /// session and deletes the temporary file — the caller only ever sees the
    /// returned `Data`.
    func finish() -> RecordedVoiceNote? {
        guard state == .recording, let recorder, let fileURL else {
            cancel()
            return nil
        }

        // If the 60s cap already stopped the recorder, `currentTime` has reset
        // to 0 (per `AVAudioRecorder` docs, valid only while recording or
        // paused) — use the known cap duration instead.
        let duration = didReachCapWhileRecording ? Self.maximumDuration : recorder.currentTime
        // Cancel the cap before tearing down. It is harmless if it fires late
        // (it re-checks `state == .recording`), but the UI can reach this via
        // `hasReachedMaximumDuration` a tick *before* the cap task wakes, so
        // without this the task would otherwise stay pending across the whole
        // remainder of the 60s window and be leaked until the next recording.
        capTask?.cancel()
        capTask = nil
        stopRecorder()

        guard duration >= Self.minimumDuration else {
            discardFile()
            teardownSession()
            resetState()
            return nil
        }

        let data = try? Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        discardFile()
        teardownSession()
        resetState()

        guard let data, !data.isEmpty else {
            errorMessage = String(localized: "Couldn't read the recorded voice note. Try again.")
            return nil
        }
        return RecordedVoiceNote(data: data, filename: filename, duration: duration)
    }

    /// Stops and discards the recording without producing a clip.
    func cancel() {
        capTask?.cancel()
        capTask = nil
        stopRecorder()
        discardFile()
        teardownSession()
        resetState()
    }

    // MARK: - Recording internals

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // `.playAndRecord`, not the seemingly-more-precise `.record`: Apple's
        // mode/category compatibility table only lists `.spokenAudio` as valid
        // alongside `.playback` and `.playAndRecord`, not `.record` — pairing
        // it with `.record` risks `setCategory` throwing at runtime on-device.
        // Same category + mode `WatchAudioEngine.startRecording()` already
        // uses successfully, with the same `.duckOthers` option so a note
        // recorded over background audio doesn't pick it up.
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
        didActivateSession = true

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(VoiceNoteFilename.generate())
        let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw WatchVoiceNoteRecorderError.couldNotStart
        }
        self.recorder = recorder
        self.fileURL = url
    }

    private func stopRecorder() {
        if recorder?.isRecording == true {
            recorder?.stop()
        }
        recorder = nil
        stopTicker()
    }

    private func discardFile() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    private func teardownSession() {
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        didActivateSession = false
    }

    private func resetState() {
        state = .idle
        elapsed = 0
        level = 0
        didReachCapWhileRecording = false
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
        logger.error("Voice note recording failed")
    }

    // MARK: - Permission

    /// Duplicated from `WatchAudioEngine.requestPermission()` rather than
    /// shared: the watch target has no common audio-permission helper, and
    /// introducing one for these two ~20-line call sites isn't worth the
    /// indirection. Keep the two copies in lockstep if the fallback logic
    /// ever needs to change.
    private func requestPermission() async -> Bool {
        if #available(watchOS 11.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                break
            }
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                break
            }
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - 60s cap

    /// Enforces `maximumDuration` with a main-actor timeout `Task`, the same
    /// mechanism `WatchAudioEngine.scheduleTimeout()` uses — rather than
    /// `AVAudioRecorder.record(forDuration:)`, which stops the recorder
    /// silently on its own timer with no callback on this type (short of
    /// adopting `AVAudioRecorderDelegate` for a single event). A `Task` gives
    /// the same one-line cancellation-on-teardown story as everywhere else in
    /// this file, and it needs to run anyway to flip `didReachCapWhileRecording`
    /// and clamp `elapsed` before the UI's own observer reacts.
    private func scheduleCap() {
        capTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDuration * 1_000_000_000))
            // Explicit hop rather than relying on this `Task {}` inheriting
            // isolation, matching `WatchAudioEngine.scheduleTimeout()`.
            await MainActor.run {
                guard let self, !Task.isCancelled, self.state == .recording else { return }
                self.capTask = nil
                self.didReachCapWhileRecording = true
                self.elapsed = Self.maximumDuration
                // Stop the physical recorder now so the mic and storage
                // aren't held open indefinitely if the UI is slow to react to
                // `hasReachedMaximumDuration`. `state` deliberately stays
                // `.recording` so `finish()` still reads the file normally.
                self.recorder?.stop()
                self.stopTicker()
            }
        }
    }

    // MARK: - Ticker (elapsed + level)

    private func startTicker() {
        stopTicker()
        // `.common` so the timer keeps firing while the crown/digital time
        // view is being interacted with, matching `ComposerVoiceNoteRecorder`.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        level = Self.smoothedLevel(previous: level, dBFS: recorder.averagePower(forChannel: 0))
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Converts `AVAudioRecorder.averagePower(forChannel:)` (dBFS, roughly
    /// -160...0) into a smoothed 0...1 UI level. `AVAudioRecorder` only
    /// exposes this power reading, not raw samples the way `WatchAudioEngine`'s
    /// tap does, so the mapping is linear-in-decibels rather than RMS-based:
    /// anything at or below `silenceFloorDb` reads as 0, anything at or above
    /// 0 dBFS reads as 1, and values between scale linearly. -50 dBFS is a
    /// generous floor for a wrist mic a few inches from a speaking mouth —
    /// quieter than that is background noise, not speech. The 0.3 exponential
    /// smoothing constant matches `WatchAudioEngine.handleTapBuffer`'s, so the
    /// two voice screens' level meters feel the same.
    private static func smoothedLevel(previous: Float, dBFS: Float) -> Float {
        let silenceFloorDb: Float = -50
        let clamped = max(silenceFloorDb, min(0, dBFS))
        let normalized = (clamped - silenceFloorDb) / (0 - silenceFloorDb)
        let smoothing: Float = 0.3
        return previous + smoothing * (normalized - previous)
    }

    deinit {
        ticker?.invalidate()
        capTask?.cancel()
    }
}

enum WatchVoiceNoteRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return String(localized: "Couldn't start recording. Try again.")
        }
    }
}
