import AVFoundation
import Foundation
import Observation
import OSLog
import os

/// Drives real-time audio capture and level monitoring for Live Voice mode on iOS.
@MainActor
@Observable
final class LiveVoiceAudioEngine {
    enum AudioError: LocalizedError, Equatable {
        case permissionDenied
        case sessionUnavailable(String)
        case engineFailed(String)
        case conversionFailed(String)
        case noAudioCaptured

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Microphone access is disabled. Please enable it in Settings.")
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

    nonisolated static let maximumRecordingDuration: TimeInterval = 60
    nonisolated private static let maximumByteCeiling = 16_000 * 2 * 60 * 2

    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    private(set) var isRecording = false
    private(set) var level: Float = 0

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "LiveVoiceAudioEngine")
    private let engine = AVAudioEngine()

    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private let pcmBuffer = OSAllocatedUnfairLock(initialState: Data())
    nonisolated(unsafe) private let tapCallbackCount = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private static let levelPublishEveryNCallbacks = 5

    private var timeoutTask: Task<Void, Never>?
    private var isTapInstalled = false
    private var didActivateSession = false

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default:
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
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

        configureAndActivateAudioSession()
        pcmBuffer.withLock { $0.removeAll(keepingCapacity: true) }
        tapCallbackCount.withLock { $0 = 0 }
        level = 0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.engineFailed("Invalid input format")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: true
        ) else {
            throw AudioError.conversionFailed("Could not create target audio format")
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioError.conversionFailed("Could not create audio converter")
        }
        self.converter = conv

        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer, targetFormat: targetFormat)
        }
        isTapInstalled = true

        do {
            try engine.start()
            isRecording = true
            scheduleTimeout()
        } catch {
            cleanupRecording()
            throw AudioError.engineFailed(error.localizedDescription)
        }
    }

    func stopRecording() async throws -> Data {
        guard isRecording else { throw AudioError.noAudioCaptured }

        timeoutTask?.cancel()
        timeoutTask = nil

        engine.stop()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        isRecording = false
        level = 0
        deactivateAudioSession()

        let rawPCM = pcmBuffer.withLock { Data($0) }
        pcmBuffer.withLock { $0.removeAll(keepingCapacity: false) }

        guard !rawPCM.isEmpty else {
            throw AudioError.noAudioCaptured
        }

        return makeWavData(fromPCM: rawPCM, sampleRate: Int(Self.targetSampleRate), channels: Int(Self.targetChannelCount))
    }

    func cancelRecording() {
        timeoutTask?.cancel()
        timeoutTask = nil

        if isRecording {
            engine.stop()
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            isRecording = false
            level = 0
            deactivateAudioSession()
        }

        pcmBuffer.withLock { $0.removeAll(keepingCapacity: false) }
    }

    private func handleTapBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let conv = converter else { return }

        let frameRatio = Double(targetFormat.sampleRate) / Double(buffer.format.sampleRate)
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * frameRatio + 10)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var hasProvidedInput = false
        let status = conv.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if !hasProvidedInput {
                hasProvidedInput = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard status != .error, let channelData = convertedBuffer.int16ChannelData else { return }
        let bytesToCopy = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size

        pcmBuffer.withLock { data in
            if data.count + bytesToCopy <= Self.maximumByteCeiling {
                data.append(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))
            }
        }

        // Calculate RMS Level for visualizer
        if let floatChannelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = floatChannelData[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(frames, 1)))
            let normalized = min(max(rms * 5.0, 0), 1)

            let count = tapCallbackCount.withLock { val -> Int in
                val += 1
                return val
            }

            if count % Self.levelPublishEveryNCallbacks == 0 {
                Task { @MainActor in
                    if self.isRecording {
                        self.level = normalized
                    }
                }
            }
        }
    }

    private func configureAndActivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            didActivateSession = true
        } catch {
            logger.error("Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        guard didActivateSession else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            didActivateSession = false
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    private func scheduleTimeout() {
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumRecordingDuration * 1_000_000_000))
            if isRecording {
                cancelRecording()
            }
        }
    }

    private func cleanupRecording() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        isRecording = false
        level = 0
        deactivateAudioSession()
    }

    private func makeWavData(fromPCM pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        var header = Data()
        let totalDataLen = pcmData.count
        let totalAudioLen = totalDataLen + 36
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2

        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(UInt32(totalAudioLen).littleEndianData)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(UInt32(16).littleEndianData) // SubChunk1Size (16 for PCM)
        header.append(UInt16(1).littleEndianData)  // AudioFormat (1 for PCM)
        header.append(UInt16(channels).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(blockAlign).littleEndianData)
        header.append(UInt16(16).littleEndianData) // BitsPerSample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(UInt32(totalDataLen).littleEndianData)

        return header + pcmData
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
