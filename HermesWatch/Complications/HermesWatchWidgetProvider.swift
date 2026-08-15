import Foundation
import WidgetKit

/// One rendered instant of the complication: "what the face shows" paired with
/// "when it was shown", per WidgetKit's `TimelineEntry` contract.
struct HermesWatchTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: HermesWatchStatusSnapshot
}

/// Supplies timelines to `HermesWatchWidget` by reading the App Group snapshot
/// the app last wrote via `HermesWatchStatusBridge` (WATCHOS_ARCHITECTURE_SPEC
/// §4) — the widget extension process has no other way to learn agent state.
///
/// watchOS complication refresh budgets are tight and not fully in the app's
/// control, so this provider deliberately asks for a long, boring refresh
/// window (15 minutes) for the idle/background case rather than polling. The
/// fast path for real updates (a stream starting, an approval landing) is the
/// app calling `WidgetCenter.shared.reloadAllTimelines()` from
/// `HermesWatchStatusBridge.write(_:)` the moment state actually changes —
/// that push, not this timeline, is what keeps the face feeling live.
struct HermesWatchTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HermesWatchTimelineEntry {
        HermesWatchTimelineEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (HermesWatchTimelineEntry) -> Void) {
        // Gallery/watch-face-picker previews want stable sample content, not
        // whatever (possibly empty) state happens to be in the App Group yet.
        if context.isPreview {
            completion(HermesWatchTimelineEntry(date: Date(), snapshot: .placeholder))
            return
        }

        completion(HermesWatchTimelineEntry(date: Date(), snapshot: HermesWatchStatusBridge.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HermesWatchTimelineEntry>) -> Void) {
        let entry = HermesWatchTimelineEntry(date: Date(), snapshot: HermesWatchStatusBridge.read())
        // A single entry, refreshed no sooner than 15 minutes out. Prompt
        // updates come from the app's explicit `reloadAllTimelines()` call, not
        // from shortening this window — see the type doc comment above.
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}
