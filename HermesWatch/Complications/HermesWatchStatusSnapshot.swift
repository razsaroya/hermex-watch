import Foundation
import OSLog
import WidgetKit

/// The glanceable state the app publishes for its complications.
///
/// A watchOS widget extension is a **separate process** from `HermesWatch` — it
/// shares no memory with `WatchServerContext` and can't make a live network call
/// on a timeline refresh (WATCHOS_ARCHITECTURE_SPEC §4). This is the entire
/// payload the app hands to the extension: small, `Codable`, and tolerant of
/// unknown/missing fields per AGENTS.md rule 3, since the app and widget binaries
/// can be mid-update relative to each other (App Store staged rollout, or a
/// TestFlight build skew) and must never crash on a stale/newer shape.
struct HermesWatchStatusSnapshot: Codable, Equatable, Sendable {
    /// Display name of the active Hermes server (`WatchServerContext.displayName`).
    let serverName: String?
    /// Whether an agent run is actively streaming right now.
    let isStreaming: Bool
    /// Name of the tool currently executing, if any (e.g. "terminal", "search").
    let activeToolName: String?
    /// Count of approvals waiting on the user (WATCHOS_ARCHITECTURE_SPEC §3.2).
    let pendingApprovalCount: Int
    /// Title of the session the watch would open on tap, if there is one.
    let activeSessionTitle: String?
    /// When this snapshot was produced, for a future "stale after N minutes" UI.
    let updatedAt: Date?

    init(
        serverName: String?,
        isStreaming: Bool,
        activeToolName: String?,
        pendingApprovalCount: Int,
        activeSessionTitle: String?,
        updatedAt: Date?
    ) {
        self.serverName = serverName
        self.isStreaming = isStreaming
        self.activeToolName = activeToolName
        self.pendingApprovalCount = pendingApprovalCount
        self.activeSessionTitle = activeSessionTitle
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case serverName
        case isStreaming
        case activeToolName
        case pendingApprovalCount
        case activeSessionTitle
        case updatedAt
    }

    /// Tolerant decoding (AGENTS.md rule 3): every field falls back to a safe
    /// default rather than throwing, so a partially-written or future-shaped
    /// snapshot in the App Group container never crashes the widget extension.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        activeToolName = try container.decodeIfPresent(String.self, forKey: .activeToolName)
        pendingApprovalCount = try container.decodeIfPresent(Int.self, forKey: .pendingApprovalCount) ?? 0
        activeSessionTitle = try container.decodeIfPresent(String.self, forKey: .activeSessionTitle)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Sample content for widget gallery / Xcode previews — never real server data.
    static var placeholder: HermesWatchStatusSnapshot {
        HermesWatchStatusSnapshot(
            serverName: "Hermes",
            isStreaming: true,
            activeToolName: "terminal",
            pendingApprovalCount: 1,
            activeSessionTitle: "Refactor SSE client",
            updatedAt: Date()
        )
    }

    /// The "nothing to show yet" state: before the app has ever written a
    /// snapshot, or after a decode failure in `HermesWatchStatusBridge.read()`.
    static var empty: HermesWatchStatusSnapshot {
        HermesWatchStatusSnapshot(
            serverName: nil,
            isStreaming: false,
            activeToolName: nil,
            pendingApprovalCount: 0,
            activeSessionTitle: nil,
            updatedAt: nil
        )
    }
}

/// App-group bridge between `HermesWatch` (writer) and the `HermesWatchWidget`
/// extension (reader). This is the only transport allowed between the two —
/// the widget extension runs out-of-process on its own timeline budget and
/// cannot see `WatchServerContext.shared` (WATCHOS_ARCHITECTURE_SPEC §4).
enum HermesWatchStatusBridge {
    /// App Group container identifier. `Config/Shared.xcconfig` defines
    /// `APP_GROUP_IDENTIFIER = group.com.uzairansar.hermesmobile$(APP_IDENTIFIER_SUFFIX)`,
    /// so the branch build (TestFlight side-by-side app, see AGENTS.md "push to
    /// branch testflight") gets a distinct group via its `-branch` suffix. That
    /// resolved value must reach this enum through the Info.plist rather than a
    /// hardcoded literal — mirrors `KeychainStore`'s `"HermesKeychainService"`
    /// lookup (`HermesMobile/Auth/KeychainStore.swift`) — with the production
    /// identifier as the fallback for contexts (like SwiftUI previews) that have
    /// no Info.plist entry.
    static let appGroupIdentifier: String = {
        Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String
            ?? "group.com.uzairansar.hermesmobile"
    }()

    /// Custom URL scheme the complications deep-link through. Distinct from
    /// `HermesDeepLink.scheme` (the iPhone app's `hermes-agent`) since this
    /// opens `HermesWatch`, a separate target with its own URL type.
    ///
    /// `HermesWatch/Resources/Info.plist` registers the actual scheme as
    /// `hermex-watch$(APP_URL_SCHEME_SUFFIX)` in `CFBundleURLTypes`, so the
    /// branch TestFlight build's watch app answers to a suffixed scheme (mirrors
    /// `APP_IDENTIFIER_SUFFIX` for `appGroupIdentifier` above) — but unlike the
    /// phone target, that plist has no plain string key mirroring the resolved
    /// value back out for runtime reads (only `HermesMobile`'s does, via
    /// `HermesURLScheme`). This reads a same-named `HermesWatchURLScheme` key
    /// so it self-corrects the moment that key is added; until then it falls
    /// back to the unsuffixed literal, same as production.
    static let deepLinkScheme: String = {
        Bundle.main.object(forInfoDictionaryKey: "HermesWatchURLScheme") as? String
            ?? "hermex-watch"
    }()

    private static let defaultsKey = "HermesWatchStatusSnapshot"

    private static let logger = Logger(
        subsystem: "com.uzairansar.hermesmobile.watchkitapp",
        category: "HermesWatchStatusBridge"
    )

    private static var defaults: UserDefaults? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            logger.error("App Group '\(appGroupIdentifier, privacy: .public)' is unavailable — check the entitlement on both targets.")
            return nil
        }
        return defaults
    }

    /// Publishes a new snapshot and asks WidgetKit to refresh the complication.
    ///
    /// Callers on the app side must debounce this — do NOT call `write` on every
    /// SSE token. `WidgetCenter.shared.reloadAllTimelines()` is not free (it
    /// schedules a fresh render pass for every family/size on the watch face),
    /// so this should fire on coarse transitions (stream started/stopped, an
    /// approval arrived/resolved) rather than per-token streaming updates.
    static func write(_ snapshot: HermesWatchStatusSnapshot) {
        guard let defaults else { return }

        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            logger.error("Failed to encode HermesWatchStatusSnapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Reads the last published snapshot. Never throws — a missing suite, a
    /// missing value, or a decode failure all resolve to `.empty` so the widget
    /// extension always has something safe to render (AGENTS.md rule 3).
    static func read() -> HermesWatchStatusSnapshot {
        guard let defaults, let data = defaults.data(forKey: defaultsKey) else {
            return .empty
        }

        do {
            return try JSONDecoder().decode(HermesWatchStatusSnapshot.self, from: data)
        } catch {
            logger.error("Failed to decode HermesWatchStatusSnapshot: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }
}
