import AVFoundation
import Foundation
import Observation
import OSLog

/// Plays synthesized speech clips back-to-back for Live Voice mode on iOS.
@MainActor
@Observable
final class LiveVoiceSpeechPlayer: NSObject, AVAudioPlayerDelegate {
    static let defaultVoice = "en-US-AriaNeural"
    private static let maximumQueuedClips = 30
    nonisolated private static let levelPollHz: Double = 15

    private(set) var isPlaying = false
    private(set) var level: Float = 0

    var onFinishedAll: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "LiveVoiceSpeechPlayer")
    private var queue: [Data] = []
    private var currentPlayer: AVAudioPlayer?
    private var levelPollTask: Task<Void, Never>?
    private var didActivateSession = false

    func enqueue(_ mp3: Data) {
        guard !mp3.isEmpty else { return }

        if queue.count >= Self.maximumQueuedClips {
            logger.warning("Speech queue at capacity; dropping oldest clip.")
            queue.removeFirst()
        }
        queue.append(mp3)

        if !isPlaying {
            playNext()
        }
    }

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
                logger.error("Failed to activate audio session for playback")
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
            player.prepareToPlay()

            guard player.play() else {
                logger.error("AVAudioPlayer.play() returned false")
                playNext()
                return
            }

            currentPlayer = player
            isPlaying = true
            startLevelPolling()
        } catch {
            logger.error("Failed to initialize AVAudioPlayer: \(error.localizedDescription)")
            playNext()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            levelPollTask?.cancel()
            levelPollTask = nil
            level = 0
            playNext()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            levelPollTask?.cancel()
            levelPollTask = nil
            level = 0
            playNext()
        }
    }

    private func startLevelPolling() {
        levelPollTask?.cancel()
        levelPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / Self.levelPollHz))
                if let player = self.currentPlayer, player.isPlaying {
                    player.updateMeters()
                    let power = player.averagePower(forChannel: 0)
                    let linear = pow(10, power / 20)
                    self.level = min(max(Float(linear) * 3.0, 0), 1)
                } else {
                    self.level = 0
                }
            }
        }
    }

    private func activateSessionForPlayback() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            didActivateSession = true
            return true
        } catch {
            logger.error("Failed to activate AVAudioSession for playback: \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateSession() {
        guard didActivateSession else { return }
        levelPollTask?.cancel()
        levelPollTask = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            didActivateSession = false
        } catch {
            logger.error("Failed to deactivate AVAudioSession: \(error.localizedDescription)")
        }
    }

    static func splitCompleteSentences(from text: String) -> (sentences: [String], remainder: String) {
        var sentences: [String] = []
        var remainder = text

        let sentenceDelimiters: CharacterSet = CharacterSet(charactersIn: ".?!;:\n\u{05BE}")
        
        while let range = remainder.rangeOfCharacter(from: sentenceDelimiters) {
            let sentence = String(remainder[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            remainder = String(remainder[range.upperBound...])
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        return (sentences, remainder)
    }
}
