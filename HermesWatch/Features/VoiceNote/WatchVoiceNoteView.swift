import Foundation
import SwiftUI

/// "Send Voice Note" screen: record a short clip, review the transcript
/// on-wrist, then send it as a chat message with the audio attached.
///
/// This is deliberately a separate screen from `WatchVoiceChatView`, not a
/// mode of it. `WatchVoiceChatView` is a live, hands-free back-and-forth
/// (record -> transcribe -> reply -> speak, no chance to review before it's
/// sent); a voice note is "leave a message" — record, see exactly what will
/// be sent, then decide. Folding both into one screen's state machine would
/// mean every review/re-record/discard state also has to make sense for the
/// live-turn flow (it doesn't: there's no reply to review), so two view
/// models with two narrower state machines is the simpler design here.
struct WatchVoiceNoteView: View {
    @State private var model: WatchVoiceNoteViewModel

    init(sessionID: String?, workspace: String?) {
        _model = State(initialValue: WatchVoiceNoteViewModel(sessionID: sessionID, workspace: workspace))
    }

    var body: some View {
        content
            .padding(.horizontal, 4)
            .navigationTitle("Voice Note")
            .onDisappear {
                model.onDisappear()
            }
    }

    /// Switches on `model.phase` alone — `WatchVoiceNoteViewModel` already
    /// transitions itself off `.recording` when the recorder hits
    /// `WatchVoiceNoteRecorder.maximumDuration`, so the view has nothing to
    /// race: there is no second, view-owned timer here that could disagree
    /// with the model about when recording ended.
    ///
    /// `.idle` and `.recording` share one `case` (and therefore one
    /// `recordingScreen` subtree) rather than being two separate cases — see
    /// `RecordButton`'s doc comment for why that shared identity matters for
    /// the hold-to-talk gesture.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .recording:
            recordingScreen
        case .transcribing:
            progressScreen(label: "Transcribing…")
        case .review:
            reviewScreen
        case .sending:
            progressScreen(label: "Sending…")
        case .sent:
            sentScreen
        case .failed(let message):
            failedScreen(message: message)
        }
    }

    // MARK: - Idle / recording

    private var isRecordingPhase: Bool { model.phase == .recording }

    private var recordingScreen: some View {
        VStack(spacing: 10) {
            if isRecordingPhase {
                HStack(spacing: 8) {
                    LevelIndicator(level: model.level)
                    Text(elapsedString)
                        .font(.title3.monospacedDigit())
                }
                ProgressView(value: durationFraction)
                    .tint(.red)
                Text("Up to \(Int(WatchVoiceNoteRecorder.maximumDuration))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Record a short voice note to send as a message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            RecordButton(
                phase: model.phase,
                onStart: { Task { await model.startRecording() } },
                onStop: { Task { await model.stopAndTranscribe() } }
            )

            if isRecordingPhase {
                // Not covered by the view model's own start/stop/success/failure
                // haptics (those are for `startRecording()`/`stopAndTranscribe()`,
                // not this discard path), so this button plays its own.
                Button {
                    WatchHaptic.tap.play()
                    model.cancelRecording()
                } label: {
                    Label("Discard", systemImage: "xmark.circle")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
    }

    private var elapsedString: String {
        let totalSeconds = Int(model.elapsed.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var durationFraction: Double {
        guard WatchVoiceNoteRecorder.maximumDuration > 0 else { return 0 }
        return min(model.elapsed / WatchVoiceNoteRecorder.maximumDuration, 1)
    }

    // MARK: - Transcribing / sending

    private func progressScreen(label: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Review

    private var reviewScreen: some View {
        VStack(spacing: 8) {
            // The only place in this screen that scrolls: a transcript can
            // run well past a 40mm screen's height, and unlike the record
            // control or the action buttons below, there is no fixed-size
            // layout that keeps it glanceable without one.
            ScrollView {
                Text(model.transcript)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            // Send: covered by the view model's own success/failure haptics
            // once `send()` resolves, so no `.tap` here.
            Button {
                Task { await model.send() }
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!model.canSend)

            HStack(spacing: 8) {
                Button {
                    WatchHaptic.tap.play()
                    Task { await model.discardAndReRecord() }
                } label: {
                    Label("Re-record", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)

                Button {
                    WatchHaptic.tap.play()
                    model.reset()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    // MARK: - Sent

    private var sentScreen: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("Sent")
                .font(.headline)

            Button {
                WatchHaptic.tap.play()
                model.reset()
            } label: {
                Label("Record another", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Failed

    private func failedScreen(message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Button {
                WatchHaptic.tap.play()
                model.reset()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)
        }
    }
}

/// Small level-reactive dot shown next to the elapsed timer while recording.
///
/// Scales with `level` using the same fixed-shape, `.animation(value:)`
/// technique `VoiceOrbView` documents at its own definition, rather than a
/// per-frame `Canvas`/`TimelineView` driver: `level` already updates on its
/// own cadence (pushed by the view model, ultimately from the audio engine's
/// observation chain), so a single animated `scaleEffect` is all that is
/// needed here and stays cheap to keep on screen for the whole recording.
private struct LevelIndicator: View {
    let level: Float

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 14, height: 14)
            .scaleEffect(1 + CGFloat(min(max(level, 0), 1)) * 0.8)
            .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The single record control shared by `.idle` and `.recording`, supporting
/// both interaction modes in one gesture:
///
/// - **Tap-to-record**: a quick tap while idle starts recording; a later,
///   separate quick tap while recording stops it.
/// - **Push-to-talk**: press and hold past `WatchVoiceNoteGesture.holdActivationDelay`
///   starts recording immediately (while still held, not at release);
///   releasing then stops it.
///
/// ### Why this one view instance spans both phases
/// `WatchVoiceNoteView.content` routes `.idle` and `.recording` through the
/// *same* `switch` case (`case .idle, .recording: recordingScreen`), so this
/// view is not torn down and replaced when `startRecording()` flips the
/// phase mid-press. That is load-bearing for push-to-talk: if a hold in
/// progress caused this view to be swapped out for a distinct "Stop" button
/// the moment recording started, the original `DragGesture`'s `onEnded`
/// would never fire for the touch already in flight (SwiftUI drops a
/// gesture's completion when its view leaves the hierarchy mid-touch), and
/// the recording would run until the duration cap with no way to stop it on
/// release. Keeping one view/one gesture across the transition means the
/// same touch is tracked start-to-finish regardless of what phase change
/// happens in between.
///
/// ### Why a timed `DragGesture`, not `LongPressGesture` + `TapGesture`
/// Composing a real `LongPressGesture(minimumDuration:)` alongside a
/// `TapGesture` was the first thing tried for the equivalent iOS control
/// (`ComposerVoiceControlButton` in
/// HermesMobile/Features/Chat/ChatComposerVoiceControls.swift) and rejected
/// there: the long-press recognizer keeps the touch claimed until its own
/// minimum duration elapses, so a quick tap released early is swallowed by
/// it and never reaches the tap recognizer. A single
/// `DragGesture(minimumDistance: 0)` reports touch-down (`onChanged`) and
/// touch-up (`onEnded`) directly, and a `DispatchWorkItem` scheduled at
/// touch-down for `WatchVoiceNoteGesture.holdActivationDelay` — cancelled if
/// the touch ends first — decides which path a press took. This mirrors that
/// iOS control's `pressGesture` exactly, adapted to this screen's phases.
///
/// ### Why the hold path must not also fire the tap path
/// `didHoldStart` is set the moment the work item fires (i.e. as soon as the
/// hold is committed) and is checked first in `onEnded`: once true, release
/// always calls `onStop()`, never `onStop()` *and* `onStart()` or `onStart()`
/// alone. Without that flag, a long hold would look at release time like "a
/// tap that happens to have been held a while" and could fire the tap
/// branch's `onStart()` on top of the recording the hold already started.
private struct RecordButton: View {
    let phase: WatchVoiceNoteViewModel.Phase
    let onStart: () -> Void
    let onStop: () -> Void

    @State private var isPressing = false
    @State private var didHoldStart = false
    @State private var pressStartDate: Date?
    @State private var holdWorkItem: DispatchWorkItem?

    private var isRecording: Bool { phase == .recording }

    var body: some View {
        Label(
            isRecording ? "Stop" : "Record",
            systemImage: isRecording ? "stop.fill" : "mic.fill"
        )
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isRecording ? Color.red : Color.accentColor)
        )
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(pressGesture)
        .accessibilityLabel(isRecording ? Text("Stop recording") : Text("Record voice note"))
        .accessibilityHint(Text("Tap to toggle, or press and hold to talk"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // VoiceOver's double-tap activation is a synthesized tap, not a
            // real touch-down/up pair, so it never crosses the hold
            // threshold below — this just toggles start/stop, same as a
            // quick tap.
            if isRecording {
                onStop()
            } else {
                onStart()
            }
        }
        // If the screen is dismissed mid-press (e.g. the user backs out via
        // the digital crown while holding), the scheduled work item would
        // otherwise still fire later on an orphaned copy of this struct and
        // call `onStart()` for a screen nobody can see. Cancelling here keeps
        // that Task-spawning call from ever firing after the view is gone.
        .onDisappear {
            cancelScheduledHoldStart()
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressing else { return }
                isPressing = true
                pressStartDate = Date()
                // Only arm the hold timer from idle: once already recording,
                // any press (tap or hold) should stop on release with no
                // threshold to wait out — there is no third mode for ending
                // a recording.
                if !isRecording {
                    scheduleHoldStart()
                }
            }
            .onEnded { _ in
                cancelScheduledHoldStart()
                let elapsed = pressStartDate.map { Date().timeIntervalSince($0) } ?? 0
                // `didHoldStart` is the primary signal (set the instant the
                // timer fires); the wall-clock check is a defensive fallback
                // for the rare case release lands within a hair of the
                // threshold and the timer hasn't dispatched yet.
                let wasHold = didHoldStart || WatchVoiceNoteGesture.isHold(pressDuration: elapsed)
                isPressing = false
                didHoldStart = false
                pressStartDate = nil

                if isRecording || wasHold {
                    onStop()
                } else {
                    onStart()
                }
            }
    }

    private func scheduleHoldStart() {
        let item = DispatchWorkItem {
            didHoldStart = true
            onStart()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WatchVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledHoldStart() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }
}

#Preview {
    WatchVoiceNoteView(sessionID: nil, workspace: nil)
}
