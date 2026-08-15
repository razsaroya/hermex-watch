import Foundation
import Observation

enum LiveVoiceState: Equatable {
    case idle
    case listening
    case thinking(toolName: String?)
    case speaking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: false
        case .listening, .thinking, .speaking: true
        }
    }
}

@MainActor
@Observable
final class LiveVoiceChatViewModel {
    private static let maxAssistantTextLength = 4000

    private(set) var state: LiveVoiceState = .idle {
        didSet {
            switch state {
            case .idle, .listening, .failed:
                isMicEnabled = true
            case .thinking, .speaking:
                isMicEnabled = false
            }
            if case .failed(let message) = state {
                errorMessage = message
            } else {
                errorMessage = nil
            }
        }
    }

    private(set) var transcript: String = ""
    private(set) var assistantText: String = ""
    private(set) var activeToolName: String?
    private(set) var errorMessage: String?

    var level: Float = 0
    var isMicEnabled: Bool = true
    var isAutoListenEnabled: Bool = true

    let session: SessionSummary
    let server: URL
    let apiClient: APIClient

    private let audio = LiveVoiceAudioEngine()
    private let player = LiveVoiceSpeechPlayer()
    private var sseClient: SSEClient?

    private var turnTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var activeStreamID: String?

    private var hasFinishedStream = false
    private var hasEnqueuedAudioThisTurn = false
    private var pendingSentences: [String] = []
    private var unspokenBuffer: String = ""

    init(session: SessionSummary, server: URL) {
        self.session = session
        self.server = server
        self.apiClient = APIClient(server: server)
    }

    func onAppear() async {
        player.onFinishedAll = { [weak self] in
            self?.handlePlaybackFinished()
        }
        startLevelObservation()
    }

    func onDisappear() {
        turnTask?.cancel()
        turnTask = nil
        ttsTask?.cancel()
        ttsTask = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""
        hasFinishedStream = true

        sseClient?.stop()
        sseClient = nil

        if let streamID = activeStreamID {
            Task {
                _ = try? await apiClient.cancelChat(streamID: streamID)
            }
            activeStreamID = nil
        }

        audio.cancelRecording()
        player.stop()
    }

    func toggleMicrophone() async {
        switch state {
        case .idle, .failed:
            await startListening()
        case .listening:
            await finishListening()
        case .thinking, .speaking:
            break
        }
    }

    func cancelCurrentTurn() {
        turnTask?.cancel()
        turnTask = nil
        ttsTask?.cancel()
        ttsTask = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""

        sseClient?.stop()
        sseClient = nil

        if let streamID = activeStreamID {
            Task {
                _ = try? await apiClient.cancelChat(streamID: streamID)
            }
            activeStreamID = nil
        }

        audio.cancelRecording()
        player.stop()
        state = .idle
    }

    private func startListening() async {
        cancelCurrentTurn()
        transcript = ""
        assistantText = ""
        activeToolName = nil
        errorMessage = nil

        do {
            try await audio.startRecording()
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func finishListening() async {
        guard state == .listening else { return }

        state = .thinking(toolName: nil)

        do {
            let wavData = try await audio.stopRecording()
            let transcriptResult = try await apiClient.transcribe(audioData: wavData, filename: "recording.wav")
            let trimmed = transcriptResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else {
                state = .failed(String(localized: "No speech detected"))
                return
            }

            self.transcript = trimmed
            await runTurn(prompt: trimmed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func runTurn(prompt: String) async {
        state = .thinking(toolName: nil)
        hasFinishedStream = false
        hasEnqueuedAudioThisTurn = false
        pendingSentences.removeAll()
        unspokenBuffer = ""
        startTTSWorker()

        do {
            let client = try await apiClient.startChat(
                sessionID: session.id,
                message: prompt
            )
            self.sseClient = client
            self.activeStreamID = client.streamID

            for await event in client.events {
                if Task.isCancelled { break }
                handleStreamEvent(event)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func handleStreamEvent(_ event: ChatStreamEvent) {
        switch event {
        case .textDelta(let delta):
            assistantText += delta
            if assistantText.count > Self.maxAssistantTextLength {
                assistantText = String(assistantText.suffix(Self.maxAssistantTextLength))
            }
            unspokenBuffer += delta

            let split = LiveVoiceSpeechPlayer.splitCompleteSentences(from: unspokenBuffer)
            if !split.sentences.isEmpty {
                pendingSentences.append(contentsOf: split.sentences)
                unspokenBuffer = split.remainder
            }

        case .toolCallStarted(let toolName):
            activeToolName = toolName
            state = .thinking(toolName: toolName)

        case .toolCallFinished:
            activeToolName = nil
            if player.isPlaying {
                state = .speaking
            } else {
                state = .thinking(toolName: nil)
            }

        case .streamEnd, .cancelled, .done:
            guard !hasFinishedStream else { return }
            hasFinishedStream = true
            activeToolName = nil

            let leftover = unspokenBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty {
                pendingSentences.append(leftover)
                unspokenBuffer = ""
            }

            if !hasEnqueuedAudioThisTurn && pendingSentences.isEmpty && !player.isPlaying {
                state = .idle
                checkAutoListen()
            }

        case .error(let error):
            state = .failed(error.message)
            cancelCurrentTurn()

        default:
            break
        }
    }

    private func startTTSWorker() {
        ttsTask?.cancel()
        ttsTask = Task { @MainActor in
            while !Task.isCancelled {
                if pendingSentences.isEmpty {
                    if hasFinishedStream { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                let sentence = pendingSentences.removeFirst()
                guard !sentence.isEmpty else { continue }

                do {
                    let audioData = try await apiClient.synthesizeSpeech(
                        text: sentence,
                        voice: LiveVoiceSpeechPlayer.defaultVoice
                    )
                    hasEnqueuedAudioThisTurn = true
                    player.enqueue(audioData)
                    state = .speaking
                } catch {
                    // Skip synthesis failure and continue next sentence
                }
            }
        }
    }

    private func handlePlaybackFinished() {
        guard hasFinishedStream && pendingSentences.isEmpty else { return }
        state = .idle
        checkAutoListen()
    }

    private func checkAutoListen() {
        guard isAutoListenEnabled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if self.state == .idle {
                await self.startListening()
            }
        }
    }

    private func startLevelObservation() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                switch state {
                case .listening:
                    self.level = audio.level
                case .speaking:
                    self.level = player.level
                default:
                    self.level = 0
                }
            }
        }
    }
}
