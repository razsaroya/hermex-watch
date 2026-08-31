import AVFoundation
import Foundation
import Observation
import OSLog
import os

/// Captures microphone audio on Apple Watch and packages it as a WAV clip
/// suitable for `POST /api/transcribe` (multipart, field `file`), per
/// WATCHOS_ARCHITECTURE_SPEC §3.1 "Audio Input."
///
/// ### Deliberate correction to WATCHOS_ARCHITECTURE_SPEC §3.1
/// The spec's "Real-time Streaming" bullet implies the server accepts a live
/// STT socket. It does not: `POST /api/transcribe` is a single multipart
/// upload of a *complete* audio clip (`TranscribeResponse { ok, transcript,
/// error }`), verified by reading `hermes-webui`'s route source (AGENTS.md
/// rule 1). There is no partial-result channel. This engine therefore records
/// into memory, and the caller uploads the whole clip only once `stopRecording()`
/// returns — there is no incremental transcript while the user is still talking.
///
/// ### Threading
/// `AVAudioEngine`'s tap callback fires on a real-time audio thread. It must
/// never touch `@MainActor` state directly or perform anything that can block
/// (locks with unbounded wait, allocation-heavy work, logging). This type
/// guards its accumulation buffer with `OSAllocatedUnfairLock` and only hops
/// to the main actor for the throttled `level` publish, using a frame counter
/// (not a timestamp read, which is itself nontrivial on a real-time thread).
@MainActor
@Observable
final class WatchAudioEngine {
    enum AudioError: LocalizedError, Equatable {
        case permissionDenied
        case sessionUnavailable(String)
        case engineFailed(String)
        case conversionFailed(String)
        case noAudioCaptured

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Microphone access is disabled. Enable it in the Watch app on your iPhone.")
            case .sessionUnavailable(let reason):
                return String(localized: "The microphone isn't available right now (\(reason)).")
            case .engineFailed(let reason):
                return String(localized: "Recording failed to start (\(reason)).")
            case .conversionFailed(let reason):
                return String(localized: "Recording could not be processed (\(reason)).")
            case .noAudioCaptured:
                return String(localized: "No audio was captured.")
            }
        }
    }

    /// Hard cap on a single recording, per the task brief ("cap the recording
    /// at 30 seconds"). Enforced by cancelling the recording from a
    /// main-actor timeout task rather than branching on the audio thread.
    /// `nonisolated` so `scheduleTimeout()`'s detached `Task {}` can read it
    /// before its first `await` without needing a main-actor hop first.
    nonisolated static let maximumRecordingDuration: TimeInterval = 30

    /// Hard ceiling on accumulated PCM bytes, independent of the duration
    /// timer, so a hardware format surprise (e.g. a higher sample rate than
    /// expected) can't grow the buffer unboundedly before the timer fires.
    /// 16 kHz * 2 bytes/sample * 30 s * 2x safety margin.
    /// `nonisolated` (a compile-time-constant `Int`, so trivially safe to
    /// share) because the audio-thread `handleTapBuffer` reads it.
    nonisolated private static let maximumByteCeiling = 16_000 * 2 * 30 * 2

    /// Target format the server's `/api/transcribe` expects: 16 kHz mono
    /// 16-bit PCM, per the task brief.
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    private(set) var isRecording = false
    /// Smoothed 0...1 RMS level, published at ~15 Hz for the listening orb.
    private(set) var level: Float = 0

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile.watchkitapp", category: "WatchAudioEngine")

    private let engine = AVAudioEngine()

    /// Set on the main actor before the tap is installed and only read after
    /// (never mutated concurrently with recording), then read from the
    /// nonisolated tap callback below. `nonisolated(unsafe)` documents that
    /// contract instead of paying for a lock on a value that never actually
    /// races — the class is `@MainActor`, so without this annotation the
    /// audio-thread callback could not touch it at all without an `await`,
    /// which a real-time thread must never do.
    nonisolated(unsafe) private var converter: AVAudioConverter?

    /// Accumulated 16-bit little-endian PCM samples, guarded because the tap
    /// callback (real-time audio thread) and `stopRecording()` (main actor)
    /// both touch it. `OSAllocatedUnfairLock` itself is `Sendable`, but the
    /// property still needs `nonisolated(unsafe)` so the tap callback (which
    /// runs off the main actor) can reach it synchronously; the lock is what
    /// actually keeps the concurrent access safe, not the actor.
    nonisolated(unsafe) private let pcmBuffer = OSAllocatedUnfairLock(initialState: Data())

    /// Frame counter used to throttle the `level` publish to ~15/s without
    /// reading a clock on the audio thread. `installTap` on watchOS typically
    /// delivers ~10 ms buffers, so ~5 callbacks ≈ 1 publish/50 ms ≈ 15/s.
    nonisolated(unsafe) private let tapCallbackCount = OSAllocatedUnfairLock(initialState: 0)
    /// `nonisolated` for the same reason as `maximumByteCeiling` above.
    nonisolated private static let levelPublishEveryNCallbacks = 5

    private var timeoutTask: Task<Void, Never>?
    private var isTapInstalled = false
    private var didActivateSession = false

    /// Requests microphone permission, preferring the watchOS 11+
    /// `AVAudioApplication` API and falling back to the older
    /// `AVAudioSession` callback API on earlier watchOS 10 devices.
    func requestPermission() async -> Bool {
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

    func startRecording() async throws {
        guard !isRecording else { return }

        guard await requestPermission() else {
            throw AudioError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` mode + `.duckOthers` per the task brief. No
            // `.defaultToSpeaker` (iOS-only) and no `.allowBluetoothA2DP`
            // (not appropriate for a record-capable category here).
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            didActivateSession = true
        } catch {
            throw AudioError.sessionUnavailable(error.localizedDescription)
        }

        pcmBuffer.withLock { $0.removeAll(keepingCapacity: false) }
        tapCallbackCount.withLock { $0 = 0 }
        level = 0

        let inputNode = engine.inputNode
        // MUST use the node's own hardware format for the tap — installing a
        // tap with a mismatched format throws/crashes on watchOS.
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.sessionUnavailable("no input format")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: true
        ) else {
            throw AudioError.conversionFailed("could not create target format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioError.conversionFailed("could not create converter")
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownTap()
            throw AudioError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        scheduleTimeout()
    }

    /// Stops capture and returns 16 kHz mono 16-bit little-endian WAV bytes
    /// (44-byte RIFF header + PCM) ready for `POST /api/transcribe`.
    func stopRecording() async throws -> Data {
        guard isRecording else { throw AudioError.noAudioCaptured }

        timeoutTask?.cancel()
        timeoutTask = nil
        teardownAndDeactivate()
        isRecording = false
        level = 0

        let samples = pcmBuffer.withLock { $0 }
        guard !samples.isEmpty else {
            throw AudioError.noAudioCaptured
        }

        return Self.wavData(
            fromPCM16: samples,
            sampleRate: Int(Self.targetSampleRate),
            channels: Int(Self.targetChannelCount)
        )
    }

    /// Stops capture and discards whatever was captured. Never throws, so
    /// callers can use it unconditionally on cancel/dismiss paths.
    func cancelRecording() {
        guard isRecording else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        teardownAndDeactivate()
        isRecording = false
        level = 0
        pcmBuffer.withLock { $0.removeAll(keepingCapacity: false) }
    }

    // MARK: - Timeout

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumRecordingDuration * 1_000_000_000))
            // Explicitly hop back to the main actor rather than relying on
            // this `Task {}` closure inheriting isolation from the method
            // that created it, matching the defensive style used elsewhere
            // in the app (see `ComposerVoiceInputController.startServerRecordingTimeout`).
            await MainActor.run {
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.logger.info("Recording hit the \(Self.maximumRecordingDuration, privacy: .public)s cap; stopping.")
                self.timeoutTask = nil
                self.teardownAndDeactivate()
                self.isRecording = false
                self.level = 0
                // Deliberately leave `pcmBuffer` intact — the next
                // `stopRecording()` call (the UI's normal "finish" path)
                // still returns whatever was captured rather than throwing,
                // matching "stop and return what we have rather than
                // growing unbounded" from the task brief.
            }
        }
    }

    // MARK: - Teardown

    private func teardownTap() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        converter = nil
    }

    private func teardownAndDeactivate() {
        teardownTap()
        if didActivateSession {
            // Deactivate so playback (WatchSpeechPlayer) can cleanly take the
            // session over afterwards. `.notifyOthersOnDeactivation` releases
            // the `.duckOthers` duck we took in `startRecording`, so whatever
            // was playing before (a workout playlist, say) returns to full
            // volume instead of staying quiet until the next route change.
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            didActivateSession = false
        }
    }

    // MARK: - Tap thread work

    /// Runs on the real-time audio thread. Converts the hardware buffer to
    /// the target 16 kHz mono Int16 format, appends it under the lock, and
    /// computes an RMS level. Only a throttled `Task { @MainActor in }` hop
    /// touches observable state.
    nonisolated private func handleTapBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let estimatedOutputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOutputFrames) else {
            return
        }

        // MUST use the block-based (pull) API here, not the simpler
        // `convert(to:from:)`. That one-shot form is documented to fail for any
        // conversion requiring a sample-rate change — and this one always is:
        // the Apple Watch input node runs at 44.1/48 kHz and the target is
        // 16 kHz. With the one-shot form every callback would throw, the
        // `catch` would silently drop the chunk, and `stopRecording()` would
        // always come back `.noAudioCaptured` — i.e. voice input would never
        // work at all. The converter is deliberately long-lived (one per
        // recording) so the resampler keeps its filter state across buffers;
        // recreating it per callback would click at every chunk boundary.
        var didSupplyInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            // The pull block may be invoked more than once per `convert` call.
            // We have exactly one input buffer, so the second and later asks
            // must report `.noDataNow` — returning the same buffer again would
            // duplicate audio.
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        // `.inputRanDry` is the normal, expected result: we fed one buffer and
        // the converter drained it. Only `.error` means nothing usable came
        // out. Either way we read `outputBuffer.frameLength` below, which is 0
        // when the resampler is still filling its internal delay line.
        if status == .error {
            return
        }

        guard outputBuffer.frameLength > 0,
              let int16Data = outputBuffer.int16ChannelData else {
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        let channelPointer = int16Data[0]
        let samples = UnsafeBufferPointer(start: channelPointer, count: frameCount)

        // RMS over this chunk, for the level meter.
        var sumSquares: Double = 0
        for sample in samples {
            let normalized = Double(sample) / Double(Int16.max)
            sumSquares += normalized * normalized
        }
        let rms = frameCount > 0 ? Float(sqrt(sumSquares / Double(frameCount))) : 0

        // `Data(buffer:)` copies the typed buffer's raw little-endian bytes
        // directly — Int16 is already the wire format we want, so no manual
        // byte-swapping is needed on the (little-endian) Apple Watch CPU.
        let chunkData = Data(buffer: samples)

        var didExceedCeiling = false
        pcmBuffer.withLock { accumulated in
            guard accumulated.count < Self.maximumByteCeiling else {
                didExceedCeiling = true
                return
            }
            accumulated.append(chunkData)
        }

        let callbackIndex = tapCallbackCount.withLock { count -> Int in
            count += 1
            return count
        }

        guard callbackIndex % Self.levelPublishEveryNCallbacks == 0 || didExceedCeiling else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            // Simple exponential smoothing so the orb doesn't flicker.
            let smoothing: Float = 0.3
            self.level = self.level + smoothing * (min(rms, 1) - self.level)
            if didExceedCeiling {
                self.logger.info("Recording hit the byte ceiling; further samples are dropped.")
            }
        }
    }

    // MARK: - WAV encoding

    /// Writes a correct canonical 44-byte RIFF/WAVE header followed by raw
    /// PCM16 data. Byte layout (all little-endian, per the task brief):
    ///   0  "RIFF"            (4 bytes, ASCII)
    ///   4  chunkSize          UInt32 = 36 + dataSize
    ///   8  "WAVE"            (4 bytes, ASCII)
    ///  12  "fmt "            (4 bytes, ASCII)
    ///  16  subchunk1Size      UInt32 = 16 (PCM)
    ///  20  audioFormat        UInt16 = 1 (PCM)
    ///  22  numChannels        UInt16
    ///  24  sampleRate         UInt32
    ///  28  byteRate           UInt32 = sampleRate * numChannels * bitsPerSample/8
    ///  32  blockAlign         UInt16 = numChannels * bitsPerSample/8
    ///  34  bitsPerSample      UInt16 = 16
    ///  36  "data"            (4 bytes, ASCII)
    ///  40  dataSize           UInt32 = samples.count
    ///  44  ... PCM samples
    private static func wavData(fromPCM16 samples: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(samples.count)
        let byteRate = UInt32(sampleRate * channels * bytesPerSample)
        let blockAlign = UInt16(channels * bytesPerSample)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44 + samples.count)
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // subchunk1Size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var result = header
        result.append(samples)
        return result
    }
}
