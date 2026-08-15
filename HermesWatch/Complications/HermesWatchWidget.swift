import Foundation
import SwiftUI
import WidgetKit

/// Static (non-Live-Activity) WidgetKit complication for `HermesWatch`, the
/// watchOS counterpart to `HermesLiveActivityWidget/AgentRunLiveActivityWidget.swift`.
/// ActivityKit Live Activities don't exist on watchOS, so this reads its state
/// from the App Group snapshot (`HermesWatchStatusBridge`) instead of an
/// `ActivityAttributes.ContentState` (WATCHOS_ARCHITECTURE_SPEC §4, Phase 4).
///
/// Deliberately `StaticConfiguration`, not `IntentConfiguration` — there is no
/// user-configurable parameter (server, filter, etc.) worth an App Intent here;
/// the complication always shows "the active server's current status".
struct HermesWatchWidget: Widget {
    let kind = "HermesWatchStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HermesWatchTimelineProvider()) { entry in
            HermesWatchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes")
        .description("Shows whether Hermes is streaming a response or waiting on your approval.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

/// Renders one `HermesWatchTimelineEntry` for whichever accessory family the
/// watch face is currently showing. All branches are monochrome-friendly (SF
/// Symbols + system text, no custom fonts/images) so they hold up under every
/// `widgetAccessoryRenderingMode` the system may apply (vibrant, accented,
/// full color) without this view having to branch on it explicitly.
struct HermesWatchWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: HermesWatchTimelineEntry

    private var presentation: HermesWatchStatusPresentation {
        HermesWatchStatusPresentation(snapshot: entry.snapshot)
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(deepLinkURL)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            circularView

        #if os(watchOS)
        case .accessoryCorner:
            cornerView
        #endif

        case .accessoryRectangular:
            rectangularView

        case .accessoryInline:
            inlineView

        default:
            // WidgetFamily gains cases across OS releases (e.g. new Home Screen
            // sizes), so an exhaustive switch here would break every future SDK
            // bump. Any family this complication isn't built for falls back to
            // the cheapest, always-safe rendering: the inline text line.
            inlineView
        }
    }

    /// `.accessoryCircular`: an SF Symbol summarizing state, with the pending
    /// approval count as a small badge when there's something to act on.
    private var circularView: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: presentation.symbolName)
                .font(.title3)
                .imageScale(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if presentation.pendingApprovalCount > 0 {
                Text(presentation.badgeText)
                    .font(.system(size: 10, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(3)
                    .background(.red, in: Circle())
            }
        }
    }

    #if os(watchOS)
    /// `.accessoryCorner`: watchOS-only family (a curved icon tucked into a
    /// corner of the Infograph-style faces) with a short `widgetLabel` arc
    /// text. There is no iOS/iPadOS equivalent, so this case only compiles
    /// when the target is watchOS — gated for clarity even though this whole
    /// target only ever builds for watchOS today.
    private var cornerView: some View {
        Image(systemName: presentation.symbolName)
            .font(.title3)
            .widgetLabel {
                Text(presentation.cornerLabelText)
            }
    }
    #endif

    /// `.accessoryRectangular`: the roomiest family — server name on top, a
    /// one-line status, then whichever is more specific: the active tool
    /// (mid-run) or the session title (idle/context). Each line is capped to
    /// one row so a long session title can never push the status off-screen.
    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(presentation.serverNameText)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)

            Label(presentation.statusText, systemImage: presentation.symbolName)
                .font(.caption2)
                .lineLimit(1)

            Text(presentation.detailText)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.accessoryInline`: text-only (no icon glyph rendering here beyond the
    /// `Label`'s system image, which some faces drop) — a single short string
    /// covering the most important fact: an approval waiting beats a stream
    /// in progress beats idle, since it's the one thing that needs the user.
    private var inlineView: some View {
        Label(presentation.inlineText, systemImage: presentation.symbolName)
    }

    /// Approvals win the tap target when any are pending — that's the more
    /// urgent destination. Otherwise land on voice, the primary watch surface
    /// (WATCHOS_ARCHITECTURE_SPEC §3.1).
    /// Optional, and deliberately not force-unwrapped: the scheme comes from an
    /// Info.plist value (`HermesWatchURLScheme`), so a typo there would turn a
    /// dead deep link into a crashing widget extension. `.widgetURL` accepts
    /// `nil` and simply makes the complication non-tappable.
    private var deepLinkURL: URL? {
        let path = presentation.pendingApprovalCount > 0 ? "approvals" : "voice"
        return URL(string: "\(HermesWatchStatusBridge.deepLinkScheme)://\(path)")
    }
}

/// Derives all display strings/symbols from a snapshot in one place so the
/// four family-specific views above stay in sync with each other rather than
/// each re-deriving "what does 'busy' mean" independently.
private struct HermesWatchStatusPresentation {
    let snapshot: HermesWatchStatusSnapshot

    var pendingApprovalCount: Int { snapshot.pendingApprovalCount }

    /// A pending approval is the most actionable state, so it wins over an
    /// in-progress stream for the glanceable symbol; idle is the fallback.
    var symbolName: String {
        if pendingApprovalCount > 0 {
            "exclamationmark.bubble.fill"
        } else if snapshot.isStreaming {
            "waveform"
        } else {
            "bolt.horizontal.circle"
        }
    }

    var badgeText: String {
        pendingApprovalCount > 9 ? "9+" : "\(pendingApprovalCount)"
    }

    var serverNameText: String {
        snapshot.serverName ?? "Hermes"
    }

    var statusText: String {
        if pendingApprovalCount == 1 {
            "1 approval waiting"
        } else if pendingApprovalCount > 1 {
            "\(pendingApprovalCount) approvals waiting"
        } else if snapshot.isStreaming {
            "Streaming"
        } else {
            "Idle"
        }
    }

    var detailText: String {
        if let activeToolName = snapshot.activeToolName, snapshot.isStreaming {
            return "Using \(activeToolName)"
        }
        if let activeSessionTitle = snapshot.activeSessionTitle {
            return activeSessionTitle
        }
        return "No active session"
    }

    var cornerLabelText: String {
        if pendingApprovalCount > 0 {
            badgeText
        } else if snapshot.isStreaming {
            "Live"
        } else {
            "Hermes"
        }
    }

    var inlineText: String {
        if pendingApprovalCount == 1 {
            "1 approval waiting"
        } else if pendingApprovalCount > 1 {
            "\(pendingApprovalCount) approvals waiting"
        } else if snapshot.isStreaming {
            snapshot.activeToolName.map { "Using \($0)" } ?? "Streaming"
        } else {
            "Hermes idle"
        }
    }
}

/// This `@main` belongs to the **`HermesWatchWidget` extension target**, not
/// the watch app target — `HermesWatchApp` (in `HermesWatch/App/`) is the
/// `@main` for the app itself. A single target can only have one `@main`
/// entry point, so these two must stay in separate targets/binaries; merging
/// this widget extension's sources into the watch app target (or vice versa)
/// is a compile error ("'main' attribute can only apply to one type"), not
/// just a style problem.
@main
struct HermesWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesWatchWidget()
    }
}

#Preview("Circular", as: .accessoryCircular) {
    HermesWatchWidget()
} timeline: {
    HermesWatchTimelineEntry(date: .now, snapshot: .placeholder)
    HermesWatchTimelineEntry(date: .now, snapshot: .empty)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    HermesWatchWidget()
} timeline: {
    HermesWatchTimelineEntry(date: .now, snapshot: .placeholder)
    HermesWatchTimelineEntry(date: .now, snapshot: .empty)
}
