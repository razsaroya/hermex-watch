import Foundation

/// Pure decision helpers for the voice-note record control's combined
/// tap-to-toggle / press-and-hold gesture (see `WatchVoiceNoteView.RecordButton`).
///
/// This mirrors `ComposerVoiceNoteGesture`
/// (HermesMobile/Features/Chat/ComposerVoiceNoteRecorder.swift), which the iOS
/// composer's mic button uses to make the same tap-vs-hold call. That type
/// lives in the `HermesMobile` target, which `HermesWatch` does not link
/// against, so it can't simply be imported here — this is a small, independent
/// copy of just the piece the watch needs. Kept free of any `View`/`Gesture`
/// state (no `@State`, no SwiftUI imports) so the threshold and the decision
/// function can be exercised by a plain unit test without spinning up a view.
enum WatchVoiceNoteGesture {
    /// A press held at least this long counts as a deliberate press-and-hold
    /// (hold-to-talk); anything released sooner is a tap. Matches
    /// `ComposerVoiceNoteGesture.holdActivationDelay` on iOS so the two apps'
    /// mic buttons feel the same in the hand/on the wrist, and matches the
    /// system long-press feel (~0.5s) closely enough that a deliberate tap —
    /// which can easily linger 0.2-0.3s — is never misread as a hold.
    static let holdActivationDelay: TimeInterval = 0.5

    /// True when a press lasting `pressDuration` should be treated as a hold
    /// rather than a tap.
    ///
    /// `RecordButton` primarily determines "this press is a hold" the moment
    /// it happens — via a timer armed for `holdActivationDelay` at touch-down,
    /// so hold-to-talk recording starts the instant the hold is committed
    /// rather than only once the finger lifts — and this function's main job
    /// there is a defensive, timer-independent cross-check applied at release
    /// (wall-clock duration since touch-down), covering the case where the
    /// timer fires a few milliseconds late under main-thread contention. When
    /// used as a standalone decision (e.g. in a test), it is the whole answer.
    static func isHold(pressDuration: TimeInterval) -> Bool {
        pressDuration >= holdActivationDelay
    }
}
