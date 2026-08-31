import Foundation
import Observation

/// Drives the "Send Voice Note" screen: record -> transcribe -> review ->
/// upload -> send, mirroring `HermesMobile` `ChatViewModel.sendVoiceNote`'s
/// semantics (Telegram-style voice note: the sent message's text is the
/// server transcript, and its sole attachment is the audio clip, rendered as
/// a playable note by the inline audio player).
///
/// Unlike the transcribe-only step inside `WatchVoiceChatViewModel.runTurn`,
/// this screen inserts a `.review` stop between transcription and sending —
/// the user sees the transcript and can re-record before anything is sent —
/// and the recorded clip itself becomes a permanent chat attachment rather
/// than a disposable STT scratch buffer.
///
/// ### Deliberately no SSE stream, no `WatchStatusPublisher.setStreaming(true)`
/// `WatchVoiceChatViewModel` opens an `SSEClient` after `startChat` because it
/// has to speak the reply back to the user turn by turn. This screen has
/// nothing to speak: once `send()` reaches a `streamId`, the agent run
/// continues entirely server-side, and the user is expected to check progress
/// from the voice-chat screen or the phone. Opening an `SSEClient` here would
/// mean draining it for no purpose, and calling
/// `WatchStatusPublisher.setStreaming(true)` would be actively harmful: this
/// screen sends and leaves (`phase` goes straight to `.sent`), so nothing on
/// it would ever call `setStreaming(false)` — the complication would show a
/// live run forever even after the run finished.
@MainActor
@Observable
final class WatchVoiceNoteViewModel {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case review
        case sending
        case sent
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            // Every non-`.failed` transition clears the error, matching
            // `WatchVoiceChatViewModel`'s `state` didSet. `stopAndTranscribe()`
            // deliberately re-populates `errorMessage` *after* setting
            // `phase = .idle` for the "clip too short/unreadable" case, so
            // that one path can still show a message while resting in `.idle`.
            if case .failed(let message) = phase {
                errorMessage = message
            } else {
                errorMessage = nil
            }
        }
    }

    private(set) var transcript: String = ""
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var errorMessage: String?
    private(set) var sessionID: String?

    var isRecording: Bool { phase == .recording }
    var canSend: Bool { phase == .review && heldClip != nil }

    private let workspace: String?
    private let recorder = WatchVoiceNoteRecorder()

    /// The most recently recorded, not-yet-sent clip. Held only between
    /// `stopAndTranscribe()` and `send()`/`discardAndReRecord()`/`onDisappear()`
    /// — never longer, since a full 60s clip is ~150 KB and there is no reason
    /// to keep it around once the screen moves past it.
    private var heldClip: WatchVoiceNoteRecorder.RecordedVoiceNote?
    /// Backs `stopAndTranscribe()` / `send()`'s network work, so
    /// `onDisappear()` can cancel it. Both of those methods do their
    /// synchronous guard-and-phase-flip *before* creating this task, which is
    /// what makes re-entrant calls a no-op (a second call sees the already-
    /// updated `phase` and bails) without needing a separate boolean flag.
    private var pipelineTask: Task<Void, Never>?
    /// True from the moment `startRecording()` is entered until `recorder.begin()`
    /// has resolved. `begin()` awaits the system microphone prompt, which on a
    /// first run can sit on screen for seconds, so `phase` is still `.idle`
    /// during that window even though the user believes they are recording.
    private var isStarting = false
    /// Set when `stopAndTranscribe()` arrives *during* that window. Push-to-talk
    /// makes this ordinary rather than exotic: press-and-hold fires
    /// `startRecording()`, and releasing before `begin()` resolves fires
    /// `stopAndTranscribe()` against a view model that is not `.recording` yet.
    /// Without this flag that stop would be swallowed by the `guard`, and the
    /// recording would start *after* the user let go and then run all the way
    /// to the 60s cap with the UI showing a screen they already released.
    private var stopRequestedWhileStarting = false

    init(sessionID: String?, workspace: String?) {
        self.sessionID = sessionID
        self.workspace = workspace
    }

    // MARK: - Recording

    func startRecording() async {
        guard phase == .idle, !isStarting else { return }
        transcript = ""
        elapsed = 0
        level = 0

        isStarting = true
        stopRequestedWhileStarting = false
        await recorder.begin()
        isStarting = false

        guard recorder.isRecording else {
            // `begin()` can fail (permission denied, engine error) or no-op
            // (the screen disappeared mid-prompt and called `cancel()`
            // underneath us); only the former has a message worth surfacing.
            stopRequestedWhileStarting = false
            if let message = recorder.errorMessage {
                fail(message)
            }
            return
        }

        // The user already let go (push-to-talk release, or a Stop tap) while
        // the permission prompt was up. Honour it: throw the clip away rather
        // than transcribing a recording that only existed after the release.
        guard !stopRequestedWhileStarting else {
            stopRequestedWhileStarting = false
            recorder.cancel()
            elapsed = 0
            level = 0
            phase = .idle
            return
        }

        WatchHaptic.start.play()
        phase = .recording
        startObservingRecorder()
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        recorder.cancel()
        elapsed = 0
        level = 0
        phase = .idle
    }

    /// Mirrors `recorder.elapsed` / `recorder.level` into this view model's
    /// own properties using the same self-terminating `withObservationTracking`
    /// pattern as `WatchVoiceChatViewModel.startObservingAudioLevel()` (no
    /// polling timer): each firing re-registers itself only while still
    /// `.recording`, so the chain stops on its own once recording ends. When
    /// the recorder reports it hit the 60s cap, this stops re-registering and
    /// drives the auto-finish directly instead.
    private func startObservingRecorder() {
        withObservationTracking {
            _ = recorder.elapsed
            _ = recorder.level
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.elapsed = self.recorder.elapsed
                self.level = self.recorder.level
                if self.recorder.hasReachedMaximumDuration {
                    await self.stopAndTranscribe()
                    return
                }
                self.startObservingRecorder()
            }
        }
    }

    // MARK: - Transcription

    func stopAndTranscribe() async {
        // Recording hasn't actually begun yet (see `isStarting`) — record the
        // intent and let `startRecording()` act on it when `begin()` resolves.
        guard !isStarting else {
            stopRequestedWhileStarting = true
            return
        }
        guard phase == .recording else { return }

        guard let clip = recorder.finish() else {
            phase = .idle
            if let message = recorder.errorMessage {
                errorMessage = message
            }
            return
        }

        WatchHaptic.stop.play()
        heldClip = clip
        transcript = ""
        elapsed = 0
        level = 0
        phase = .transcribing

        pipelineTask = Task { [weak self] in
            await self?.runTranscribe(clip: clip)
        }
    }

    private func runTranscribe(clip: WatchVoiceNoteRecorder.RecordedVoiceNote) async {
        defer { pipelineTask = nil }

        guard let client = WatchServerContext.shared.client() else {
            fail("No server configured. Set up Hermex on your iPhone.")
            return
        }
        if Task.isCancelled { return }

        do {
            let response = try await client.transcribeAudio(data: clip.data, filename: clip.filename)
            if Task.isCancelled { return }

            if let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !serverError.isEmpty {
                fail(serverError)
                return
            }
            let text = (response.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                fail("Didn't catch that. Try recording again.")
                return
            }
            transcript = text
            phase = .review
        } catch {
            handleFailure(error)
        }
    }

    // MARK: - Review

    func discardAndReRecord() async {
        guard phase == .review else { return }
        heldClip = nil
        transcript = ""
        elapsed = 0
        level = 0
        phase = .idle
    }

    // MARK: - Send

    func send() async {
        guard phase == .review, let clip = heldClip else { return }
        guard clip.data.count <= PendingAttachment.maximumUploadBytes else {
            fail(PendingAttachment.uploadTooLargeMessage(filename: clip.filename))
            return
        }

        // This flip happens synchronously (no `await` since the top of this
        // method), so it is the reentrancy guard: a second concurrent call to
        // `send()` sees `phase != .review` and bails, the same way
        // `ChatViewModel.sendVoiceNote`'s `guard !isSendingVoiceNote` does.
        phase = .sending

        pipelineTask = Task { [weak self] in
            await self?.runSend(clip: clip)
        }
    }

    private func runSend(clip: WatchVoiceNoteRecorder.RecordedVoiceNote) async {
        defer { pipelineTask = nil }

        guard let client = WatchServerContext.shared.client() else {
            fail("No server configured. Set up Hermex on your iPhone.")
            return
        }
        if Task.isCancelled { return }

        // 1. Create a session first if this view model wasn't handed one,
        //    exactly as `WatchVoiceChatViewModel.runTurn` does.
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
                    return
                }
                sessionID = newSessionID
            } catch {
                handleFailure(error)
                return
            }
        }
        if Task.isCancelled { return }
        guard let activeSessionID = sessionID else {
            fail("No session available.")
            return
        }

        // 2. Upload the clip and map the response to a `PendingAttachment`
        //    exactly as `ChatAttachmentCoordinator.uploadStandaloneAttachment`
        //    does: same nil-fallback defaults, same `response.error` handling,
        //    no thumbnail (this is never an image).
        let uploadResponse: UploadResponse
        do {
            uploadResponse = try await client.uploadFile(sessionID: activeSessionID, data: clip.data, filename: clip.filename)
        } catch {
            handleFailure(error)
            return
        }
        if Task.isCancelled { return }
        if let uploadError = uploadResponse.error {
            fail(uploadError)
            return
        }
        guard let path = uploadResponse.path, !path.isEmpty else {
            fail("The server did not return the uploaded file path.")
            return
        }
        let pending = PendingAttachment(
            name: clip.filename,
            path: path,
            mime: uploadResponse.mime ?? "application/octet-stream",
            size: uploadResponse.size,
            isImage: uploadResponse.isImage ?? false,
            thumbnailData: nil
        )
        if Task.isCancelled { return }

        // 3. Send a chat message whose text is the BARE transcript. Copied
        //    from `ChatViewModel.sendVoiceNote` step 3: do NOT append an
        //    "[Attached files: …]" suffix (`PendingAttachment.chatMessageText`)
        //    here. The server strips attachment metadata before the model call
        //    and never embeds audio, so that suffix is the agent's only signal
        //    about a non-image attachment — it makes the agent try to
        //    "inspect"/transcribe the clip itself instead of just answering
        //    the transcript (#330). The clip still rides along in
        //    `attachments` purely so the inline player renders and persists
        //    it; it never reaches the model as text.
        let startResponse: ChatStartResponse
        do {
            startResponse = try await client.startChat(
                sessionID: activeSessionID,
                message: transcript,
                workspace: workspace,
                model: nil,
                attachments: [pending.toJSONValue()]
            )
        } catch {
            handleFailure(error)
            return
        }
        guard startResponse.error == nil, let streamID = startResponse.streamId, !streamID.isEmpty else {
            fail(startResponse.error ?? "Could not reach the assistant.")
            return
        }

        // Deliberately not tracked further — see the type doc's "no SSE
        // stream" note. The run continues server-side; this screen is done.
        heldClip = nil
        WatchHaptic.success.play()
        phase = .sent
    }

    // MARK: - Reset

    /// Clears the screen back to a usable state. Backs three different buttons:
    /// "Discard" on the review screen, "Record another" after a send, and
    /// "Try Again" after a failure.
    func reset() {
        switch phase {
        case .recording, .transcribing, .sending:
            // Something is in flight. `cancelRecording()` / `onDisappear()` are
            // the paths that may interrupt those; this one must not, or it
            // would strand the recorder or an in-flight upload.
            return
        case .idle, .review, .sent, .failed:
            break
        }

        // A send that failed after the clip was already recorded and
        // transcribed keeps both, so "Try Again" returns to the review screen
        // with the same note ready to re-send. Making the user re-record a
        // note they already approved because the Wi-Fi blipped mid-upload
        // would be the wrong trade on a device where recording is the
        // expensive part. A *transcription* failure has no transcript to go
        // back to, so it falls through and starts over.
        if isFailed, heldClip != nil, !transcript.isEmpty {
            phase = .review
            return
        }

        heldClip = nil
        transcript = ""
        elapsed = 0
        level = 0
        phase = .idle
    }

    func onDisappear() {
        // Deliberately does NOT cancel an in-flight `.sending` pipeline.
        // Cancelling it would cancel the underlying `URLSession` task, so a
        // user who taps Send and immediately drops their wrist or swipes back
        // — the expected gesture for a fire-and-forget voice note — would
        // silently send nothing. The task holds `self` weakly and every
        // continuation past this point is either a no-op or a write to a view
        // model nobody is observing, so letting it run to completion costs a
        // few hundred bytes and finishes the send the user asked for.
        // `.transcribing` has no such contract (nothing has been sent yet), so
        // it is cancelled like everything else.
        if phase != .sending {
            pipelineTask?.cancel()
            pipelineTask = nil
            heldClip = nil
        }
        recorder.cancel()
    }

    // MARK: - Failure helpers

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        WatchHaptic.failure.play()
    }

    private func handleFailure(_ error: Error) {
        guard !Task.isCancelled else { return }
        if let apiError = error as? APIError, case .unauthorized = apiError {
            WatchServerContext.shared.markAuthenticated(false)
            fail("Sign in on iPhone")
        } else {
            fail(error.localizedDescription)
        }
    }
}
