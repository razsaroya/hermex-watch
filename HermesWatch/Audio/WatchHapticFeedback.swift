import WatchKit

/// Haptics are the primary confirmation channel on the wrist, per
/// WATCHOS_ARCHITECTURE_SPEC §3.2 "Watch Action Approvals (Remote Control)":
/// a single tap approving/denying a dangerous command needs an immediate,
/// glanceable confirmation that doesn't depend on the user re-focusing on the
/// tiny screen the way an iPhone toast or animation would. Every state
/// transition the voice/approval flows care about should have a
/// corresponding haptic so the interaction is confirmable "blind" (watch
/// lowered, glance away, etc).
enum WatchHaptic {
    /// A lightweight acknowledgement — e.g. a button press that isn't itself
    /// a meaningful outcome (starting to record, dismissing a sheet).
    case tap
    /// A positive outcome — e.g. an approval was sent, a message finished
    /// sending.
    case success
    /// A negative outcome — e.g. a request failed, a denial was sent.
    case failure
    /// The beginning of a longer-running operation — e.g. listening started.
    case start
    /// The end of a longer-running operation — e.g. listening stopped.
    case stop
    /// An incoming event the user didn't directly trigger — e.g. an approval
    /// request arrived from the agent while the watch was idle.
    case notification

    /// `WKInterfaceDevice` is main-actor bound (it's UI-adjacent, like
    /// `UIDevice`), so this is itself `@MainActor` rather than dispatching
    /// internally — callers await/call it from the main actor the same way
    /// they'd touch any other UI-adjacent API.
    @MainActor
    func play() {
        WKInterfaceDevice.current().play(wkHapticType)
    }

    private var wkHapticType: WKHapticType {
        switch self {
        case .tap: .click
        case .success: .success
        case .failure: .failure
        case .start: .start
        case .stop: .stop
        case .notification: .notification
        }
    }
}
