import Foundation

/// Single writer for the complication's App Group snapshot.
///
/// `HermesWatchStatusBridge.write(_:)` calls `WidgetCenter.reloadAllTimelines()`,
/// which schedules a render pass for every family on every watch face — its own
/// doc comment warns callers to debounce rather than fire it per SSE token. This
/// type is that debounce: the feature code reports *facts* ("a stream started",
/// "the tool changed to terminal", "two approvals are waiting") and this
/// composes them into one snapshot, writing only when the meaningful content
/// actually differs from what was last written.
///
/// It exists because the complication has no other data source — the widget runs
/// out-of-process and cannot see `WatchServerContext` (see
/// `HermesWatch/Complications/HermesWatchStatusSnapshot.swift`). Without a
/// writer the complication renders `.empty` forever, so every state transition
/// worth glancing at has to be reported here.
@MainActor
final class WatchStatusPublisher {
    static let shared = WatchStatusPublisher()

    private var isStreaming = false
    private var activeToolName: String?
    private var activeSessionTitle: String?
    private var pendingApprovalCount = 0

    /// Last snapshot handed to the bridge, used to suppress no-op writes.
    private var lastPublished: HermesWatchStatusSnapshot?

    private init() {}

    /// Reports whether an agent run is in flight, and which session it belongs
    /// to. Called on the coarse transitions only (turn started / turn finished),
    /// never per token.
    func setStreaming(_ streaming: Bool, sessionTitle: String?) {
        isStreaming = streaming
        activeSessionTitle = sessionTitle
        if !streaming {
            activeToolName = nil
        }
        publishIfChanged()
    }

    /// Reports the currently executing tool (`nil` when none), so the
    /// rectangular family can show "Using terminal".
    func setActiveTool(_ name: String?) {
        activeToolName = name
        publishIfChanged()
    }

    /// Reports how many approvals are waiting on the user. This is the highest-
    /// value thing the complication shows, so it always forces a fresh check.
    func setPendingApprovalCount(_ count: Int) {
        pendingApprovalCount = max(0, count)
        publishIfChanged()
    }

    /// Rebuilds the snapshot from current state and writes it only if anything
    /// a viewer would notice changed. `updatedAt` is excluded from that
    /// comparison on purpose — it differs on every call by construction, so
    /// including it would defeat the whole debounce.
    private func publishIfChanged() {
        let snapshot = HermesWatchStatusSnapshot(
            serverName: WatchServerContext.shared.baseURL == nil
                ? nil
                : WatchServerContext.shared.displayName,
            isStreaming: isStreaming,
            activeToolName: activeToolName,
            pendingApprovalCount: pendingApprovalCount,
            activeSessionTitle: activeSessionTitle,
            updatedAt: Date()
        )

        if let lastPublished, Self.isVisuallyEquivalent(lastPublished, snapshot) {
            return
        }

        lastPublished = snapshot
        HermesWatchStatusBridge.write(snapshot)
    }

    private static func isVisuallyEquivalent(
        _ lhs: HermesWatchStatusSnapshot,
        _ rhs: HermesWatchStatusSnapshot
    ) -> Bool {
        lhs.serverName == rhs.serverName
            && lhs.isStreaming == rhs.isStreaming
            && lhs.activeToolName == rhs.activeToolName
            && lhs.pendingApprovalCount == rhs.pendingApprovalCount
            && lhs.activeSessionTitle == rhs.activeSessionTitle
    }
}
