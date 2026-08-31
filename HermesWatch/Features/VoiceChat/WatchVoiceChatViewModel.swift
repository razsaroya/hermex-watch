import Foundation
import Observation

/// Drives one voice-chat screen's worth of turns: record -> transcribe ->
/// (create session if needed) -> start chat -> stream the reply -> speak it.
///
/// Everything here runs on `@MainActor`: `WatchAudioEngine`, `WatchSpeechPlayer`
/// and `SSEClient` are all main-actor types, and every mutable property below
/// is read directly by SwiftUI, so there is no separate background actor to
/// hand off to.
///
/// ### Text-to-speech ordering
/// The server streams the assistant reply token by token; naively firing a
/// `synthesizeSpeech` call per token (or per chunk) would let network timing
/// reorder the audio. Instead, incoming tokens accumulate in `unspokenBuffer`,
/// `WatchSpeechPlayer.splitCompleteSentences` peels off whole sentences as they
/// become available, and those sentences are pushed onto `pendingSentences` —
/// a queue drained one item at a time by a single `ttsTask`. That task is the
/// only place that calls `synthesizeSpeech`, so sentences are always
/// synthesized (and therefore enqueued for playback) in the order the model
/// produced them.
///
/// ### Ending a turn
/// The SSE stream's terminal frames (`.streamEnd`, `.cancelled`, `.done`) only
/// mean "no more text is coming" — audio already queued on `WatchSpeechPlayer`
/// may still be playing. Rather than racing `WatchSpeechPlayer.isPlaying`
/// (which may not have flipped to `true` yet for audio just handed to it), the
/// view model treats `WatchSpeechPlayer.onFinishedAll` as the single source of
/// truth for "the turn is completely over" whenever any audio was queued this
/// turn; the stream-end handler only short-circuits straight to `.idle` when
/// the reply never produced any speakable text at all.
@MainActor
@Observable
final class WatchVoiceChatViewModel {
    /// Keeps `assistantText` from growing without bound across a very long,
    /// many-tool-call run. Only the most recently received text is kept once
    /// the cap is exceeded; this is a display cap only and does not affect
    /// what has already been spoken.
    private static let maxAssistantTextLength = 4000

    private(set) var state: WatchVoiceState = .idle {
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

    /// Mic level while `.listening`, playback level while `.speaking`. Kept in
    /// sync with `audio.level` / `player.level` via `withObservationTracking`
    /// rather than a polling timer — see `startObservingAudioLevel()` /
    /// `startObservingPlayerLevel()`.
    var level: Float = 0
    var isMicEnabled: Bool = true

    private let workspace: String?
    private(set) var sessionID: String?

    private let audio = WatchAudioEngine()
    private let player = WatchSpeechPlayer()
    private var sseClient: SSEClient?

    private var turnTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var activeStreamID: String?

    private var hasRequestedMicPermission = false
    /// Set once per turn the first time a terminal SSE frame
    /// (`.streamEnd` / `.cancelled` / `.done`) is observed, so a duplicate
    /// terminal frame (e.g. `.done` followed by `.streamEnd`) is a no-op.
    private var hasFinishedStream = false
    /// Set once per turn the first time any sentence is queued for TTS, so
    /// stream-end handling knows whether to wait for
    /// `WatchSpeechPlayer.onFinishedAll` or finish immediately.
    private var hasEnqueuedAudioThisTurn = false

    /// Complete sentences awaiting synthesis, in speaking order. Drained
    /// strictly one at a time by `drainTTSQueue()`.
    private var pendingSentences: [String] = []
    /// Assistant text received but not yet split into a complete sentence.
    private var unspokenBuffer: String = ""

    init(sessionID: String?, workspace: String?) {
        self.sessionID = sessionID
        self.workspace = workspace
    }

    func onAppear() async {
        player.onFinishedAll = { [weak self] in
            self?.handlePlaybackFinished()
        }
        // Approvals can be raised by work already running server-side when this
        // screen opens — not only by a turn started from here — so subscribe to
        // the session's own approval stream too. The chat stream also carries
        // `.approvalPending`; `WatchApprovalCenter` de-dupes by approval id, so
        // the overlap costs nothing.
        if let sessionID {
            WatchApprovalCenter.shared.startWatching(sessionID: sessionID)
        }
    }

    func onDisappear() {
        let client = WatchServerContext.shared.client()
        let streamID = activeStreamID

        turnTask?.cancel()
        turnTask = nil
        ttsTask?.cancel()
        ttsTask = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""
        hasFinishedStream = true

        sseClient?.stop()
        sseClient = nil
        activeStreamID = nil

        audio.cancelRecording()
        player.stop()
        WatchApprovalCenter.shared.stopWatching()
        WatchStatusPublisher.shared.setStreaming(false, sessionTitle: nil)

        if let client, let streamID {
            Task {
                _ = try? await client.cancelChat(streamID: streamID)
            }
        }
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

    func cancelCurrentTurn() async {
        let client = WatchServerContext.shared.client()
        let streamID = activeStreamID

        turnTask?.cancel()
        turnTask = nil
        ttsTask?.cancel()
        ttsTask = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""
        hasEnqueuedAudioThisTurn = false
        hasFinishedStream = true

        sseClient?.stop()
        sseClient = nil
        activeStreamID = nil
        activeToolName = nil

        audio.cancelRecording()
        player.stop()

        if let client, let streamID {
            Task {
                _ = try? await client.cancelChat(streamID: streamID)
            }
        }

        level = 0
        state = .idle
        WatchStatusPublisher.shared.setStreaming(false, sessionTitle: nil)
    }

    // MARK: - Listening

    private func startListening() async {
        level = 0
        if !hasRequestedMicPermission {
            hasRequestedMicPermission = true
            let granted = await audio.requestPermission()
            if !granted {
                fail("Microphone access is off. Enable it on your iPhone's Watch app.")
                return
            }
        }
        WatchHaptic.start.play()
        do {
            try await audio.startRecording()
        } catch {
            fail(Self.message(for: error))
            return
        }
        transcript = ""
        assistantText = ""
        activeToolName = nil
        state = .listening
        startObservingAudioLevel()
    }

    private func finishListening() async {
        level = 0
        let data: Data
        do {
            data = try await audio.stopRecording()
        } catch {
            fail(Self.message(for: error))
            return
        }
        WatchHaptic.stop.play()
        state = .thinking(toolName: nil)
        turnTask = Task { [weak self] in
            await self?.runTurn(audioData: data)
        }
    }

    // MARK: - Turn pipeline

    private func runTurn(audioData: Data) async {
        guard let client = WatchServerContext.shared.client() else {
            fail("No server configured. Set up Hermex on your iPhone.")
            turnTask = nil
            return
        }

        let transcribed: TranscribeResponse
        do {
            transcribed = try await client.transcribeAudio(data: audioData, filename: "voice.wav")
        } catch {
            handleTurnFailure(error)
            return
        }
        if Task.isCancelled {
            turnTask = nil
            return
        }

        guard transcribed.error == nil, let rawTranscript = transcribed.transcript else {
            fail(transcribed.error ?? "Didn't catch that. Try again.")
            turnTask = nil
            return
        }
        let trimmedTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            fail("Didn't catch that. Try again.")
            turnTask = nil
            return
        }
        transcript = trimmedTranscript

        if sessionID == nil {
            do {
                let response = try await client.createSession(
                    workspace: workspace,
                    model: nil,
                    modelProvider: nil,
                    profile: nil
                )
                guard let newSessionID = response.session?.sessionId, !newSessionID.isEmpty else {
                    fail("Could not start a session on the server.")
                    turnTask = nil
                    return
                }
                sessionID = newSessionID
            } catch {
                handleTurnFailure(error)
                return
            }
        }
        if Task.isCancelled {
            turnTask = nil
            return
        }
        guard let activeSessionID = sessionID else {
            fail("No session available.")
            turnTask = nil
            return
        }

        let startResponse: ChatStartResponse
        do {
            startResponse = try await client.startChat(
                sessionID: activeSessionID,
                message: trimmedTranscript,
                workspace: workspace,
                model: nil
            )
        } catch {
            handleTurnFailure(error)
            return
        }
        guard startResponse.error == nil,
              let streamID = startResponse.streamId,
              !streamID.isEmpty
        else {
            fail(startResponse.error ?? "Could not reach the assistant.")
            turnTask = nil
            return
        }
        if Task.isCancelled {
            Task {
                _ = try? await client.cancelChat(streamID: streamID)
            }
            turnTask = nil
            return
        }

        assistantText = ""
        unspokenBuffer = ""
        pendingSentences.removeAll()
        hasFinishedStream = false
        hasEnqueuedAudioThisTurn = false
        activeToolName = nil
        activeStreamID = streamID
        state = .thinking(toolName: nil)
        // Coarse transition only — the complication's App Group write triggers
        // a WidgetKit reload, so this must never be driven per token.
        WatchStatusPublisher.shared.setStreaming(true, sessionTitle: trimmedTranscript)

        let stream = SSEClient()
        sseClient = stream
        let url = client.chatStreamURL(streamID: streamID)
        stream.start(url: url) { [weak self] event in
            self?.handleSSEEvent(event)
        }
        turnTask = nil
    }

    private func handleTurnFailure(_ error: Error) {
        guard !Task.isCancelled else {
            turnTask = nil
            return
        }
        if let apiError = error as? APIError, case .unauthorized = apiError {
            handleUnauthorized()
        } else {
            fail(Self.message(for: error))
        }
        turnTask = nil
    }

    // MARK: - SSE handling

    private func handleSSEEvent(_ event: SSEEvent) {
        switch event {
        case .token(let text):
            appendAssistantText(text)

        case .interimAssistant, .reasoning, .title, .metering, .pendingSteerLeftover, .heartbeat, .ignored:
            break

        case .toolStarted(let tool):
            activeToolName = tool.name
            state = .thinking(toolName: tool.name)
            WatchStatusPublisher.shared.setActiveTool(tool.name)

        case .toolCompleted:
            activeToolName = nil
            if case .thinking = state {
                state = .thinking(toolName: nil)
            }
            WatchStatusPublisher.shared.setActiveTool(nil)

        case .approvalPending(let response):
            // `pending`/`sessionID` on the center are `private(set)`;
            // `present(_:sessionID:)` is the only mutation entry point, and it
            // is also what plays the arrival haptic and de-dupes a repeated
            // delivery of the same approval id.
            guard let pending = response.pending, !pending.isEmpty,
                  let activeSessionID = sessionID
            else { return }
            WatchApprovalCenter.shared.present(pending, sessionID: activeSessionID)

        case .clarificationPending:
            break

        case .done, .streamEnd, .cancelled:
            finishStreamIfNeeded()

        case .error(let message):
            failStream(message: message)

        case .transportError(let message):
            failStream(message: message)
        }
    }

    private func appendAssistantText(_ token: String) {
        guard !token.isEmpty else { return }

        assistantText.append(token)
        if assistantText.count > Self.maxAssistantTextLength {
            assistantText = String(assistantText.suffix(Self.maxAssistantTextLength))
        }

        unspokenBuffer.append(token)
        let (sentences, remainder) = WatchSpeechPlayer.splitCompleteSentences(unspokenBuffer)
        guard !sentences.isEmpty else { return }
        unspokenBuffer = remainder
        enqueueSentencesForSpeech(sentences)
    }

    private func finishStreamIfNeeded() {
        guard !hasFinishedStream else { return }
        hasFinishedStream = true
        sseClient?.stop()
        sseClient = nil
        activeStreamID = nil
        activeToolName = nil
        flushRemainingBufferToSpeech()
    }

    private func flushRemainingBufferToSpeech() {
        let trimmed = unspokenBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        unspokenBuffer = ""
        if !trimmed.isEmpty {
            enqueueSentencesForSpeech([trimmed])
        }
        // Finish now if the speech pipeline has nothing left to do. Testing
        // `hasEnqueuedAudioThisTurn` instead would deadlock the common short
        // reply: "Done." is synthesized and finishes playing *before*
        // `.streamEnd` arrives, so `onFinishedAll` already fired and returned
        // early (the stream hadn't ended yet). By the time we get here there is
        // no further audio to trigger it again, and the turn would sit in
        // `.speaking` with the mic disabled until the user hit Cancel.
        if isSpeechPipelineIdle {
            finishTurn()
        }
    }

    /// True when nothing is queued for synthesis, no synthesis is in flight,
    /// and nothing is playing — i.e. no future `onFinishedAll` is coming.
    private var isSpeechPipelineIdle: Bool {
        pendingSentences.isEmpty && ttsTask == nil && !player.isPlaying
    }

    private func failStream(message: String) {
        guard !hasFinishedStream else { return }
        hasFinishedStream = true
        sseClient?.stop()
        sseClient = nil
        activeStreamID = nil
        activeToolName = nil
        ttsTask?.cancel()
        ttsTask = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""
        player.stop()
        fail(message)
    }

    // MARK: - Text-to-speech queue

    private func enqueueSentencesForSpeech(_ sentences: [String]) {
        let cleaned = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        pendingSentences.append(contentsOf: cleaned)
        hasEnqueuedAudioThisTurn = true
        startTTSTaskIfNeeded()
    }

    private func startTTSTaskIfNeeded() {
        guard ttsTask == nil else { return }
        ttsTask = Task { [weak self] in
            await self?.drainTTSQueue()
        }
    }

    /// Pulls sentences off `pendingSentences` one at a time and synthesizes
    /// each in turn. Deliberately sequential (no concurrent `synthesizeSpeech`
    /// calls) so playback order always matches speaking order, even though
    /// more sentences may be appended to the queue while this loop awaits.
    private func drainTTSQueue() async {
        guard let client = WatchServerContext.shared.client() else {
            ttsTask = nil
            return
        }

        while !pendingSentences.isEmpty {
            if Task.isCancelled { break }
            let sentence = pendingSentences.removeFirst()
            do {
                let mp3 = try await client.synthesizeSpeech(text: sentence, voice: WatchSpeechPlayer.defaultVoice)
                if Task.isCancelled { break }
                if case .speaking = state {
                    // Already speaking; nothing to change.
                } else {
                    state = .speaking
                    startObservingPlayerLevel()
                }
                player.enqueue(mp3)
            } catch {
                if let apiError = error as? APIError, case .unauthorized = apiError {
                    handleUnauthorized()
                    pendingSentences.removeAll()
                    break
                }
                // Best-effort: skip a sentence that failed to synthesize
                // rather than aborting the rest of the reply.
                continue
            }
        }

        ttsTask = nil
    }

    private func handlePlaybackFinished() {
        guard hasFinishedStream, isSpeechPipelineIdle else { return }
        finishTurn()
    }

    // MARK: - Level observation

    /// Mirrors `audio.level` into `level` while `.listening`, using
    /// `withObservationTracking` (event-driven) rather than a polling timer.
    /// Each firing re-registers itself only while still `.listening`, so the
    /// chain naturally stops once recording ends.
    private func startObservingAudioLevel() {
        withObservationTracking {
            _ = audio.level
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.level = self.audio.level
                if case .listening = self.state {
                    self.startObservingAudioLevel()
                }
            }
        }
    }

    /// Mirrors `player.level` into `level` while `.speaking`. Same
    /// self-terminating pattern as `startObservingAudioLevel()`.
    private func startObservingPlayerLevel() {
        withObservationTracking {
            _ = player.level
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.level = self.player.level
                if case .speaking = self.state {
                    self.startObservingPlayerLevel()
                }
            }
        }
    }

    // MARK: - Terminal helpers

    private func fail(_ message: String) {
        state = .failed(message)
        // Every terminal path funnels through here, so this is the one place
        // that reliably clears "streaming" off the watch face — a failed turn
        // must not leave the complication showing a live run forever.
        WatchStatusPublisher.shared.setStreaming(false, sessionTitle: nil)
        WatchHaptic.failure.play()
    }

    private func handleUnauthorized() {
        WatchServerContext.shared.markAuthenticated(false)
        let client = WatchServerContext.shared.client()
        let streamID = activeStreamID

        sseClient?.stop()
        sseClient = nil
        activeStreamID = nil
        pendingSentences.removeAll()
        unspokenBuffer = ""

        fail("Sign in on iPhone")

        if let client, let streamID {
            Task {
                _ = try? await client.cancelChat(streamID: streamID)
            }
        }
    }

    private func finishTurn() {
        activeToolName = nil
        turnTask = nil
        WatchStatusPublisher.shared.setStreaming(false, sessionTitle: nil)
        if case .failed = state {
            return
        }
        level = 0
        state = .idle
    }

    private static func message(for error: Error) -> String {
        error.localizedDescription
    }
}
