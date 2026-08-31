import Foundation
import OSLog
import WatchConnectivity

/// Bridges the paired iPhone's active server/session state onto the watch via
/// `WCSession`, per WATCHOS_ARCHITECTURE_SPEC §4 ("WatchConnectivity (Phone
/// Pairing Sync)").
///
/// ### Wire format (this file owns both ends of decoding)
/// The iPhone is expected to push an *application context* — a `[String: Any]`
/// property-list dictionary — shaped like:
/// ```
/// [
///   "server_url":    String,          // the active ServerAccount's base URL
///   "display_name":  String?,         // ServerAccount.displayName, if any
///   "headers":       String?,         // [CustomHeader].encodedForStorage() JSON
///   "sessions":      Data?,           // JSON-encoded [WatchSessionSnapshot]
///   "auth_cookies":  [[String: Any]]?,// session cookies scoped to server_url
///   "signed_out":    Bool?            // true => the user signed out on the phone
/// ]
/// ```
/// `requestSync()`'s reply payload uses the identical shape, so both paths
/// funnel through `apply(applicationContext:)`.
///
/// ### The sending half
/// `HermesMobile/Connectivity/PhoneConnectivityManager.swift` owns the iPhone
/// side and pushes this context whenever the active server, the server list, or
/// the custom headers change. Keep the two files' key names in sync.
///
/// When the phone has never been in range, the watch falls back to
/// `WatchCredentialStore` (its own last-synced Keychain snapshot) and talks to
/// the server directly.
@MainActor
@Observable
final class WatchConnectivityManager {
    static let shared = WatchConnectivityManager()

    /// Whether the paired iPhone is currently reachable for an interactive
    /// `sendMessage` round trip. `false` is a normal, expected state (phone
    /// asleep, out of Bluetooth range, or app not foregrounded) — every caller
    /// must degrade gracefully rather than treat it as an error.
    private(set) var isReachable: Bool = false
    /// Wall-clock time of the last successfully applied sync payload, shown in
    /// the UI as a staleness hint (e.g. "Synced 3m ago").
    private(set) var lastSyncedAt: Date?
    /// The phone's most recently pushed session list snapshot, used by
    /// `QuickSessionsView` to render something before/without a direct server
    /// round trip.
    private(set) var recentSessions: [WatchSessionSnapshot] = []

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile.watchkitapp", category: "Connectivity")
    /// Strong reference to the delegate bridge — `WCSession.delegate` is `weak`,
    /// so something must own this or it is deallocated immediately after
    /// `activate()` returns and every subsequent callback silently drops.
    private var delegateBridge: SessionDelegateBridge?

    private init() {}

    /// Activates the `WCSession` for this process. Safe to call multiple times
    /// (e.g. once at app launch and again if `scenePhase` churns) — re-assigning
    /// the same delegate and re-calling `activate()` is a documented no-op past
    /// the first successful activation.
    func activate() {
        guard WCSession.isSupported() else {
            // Expected on watchOS simulators/devices with no paired iPhone at
            // all (vs. merely unreachable) — log at a low level, not an error.
            logger.notice("WCSession.isSupported() is false; connectivity sync disabled.")
            return
        }

        let session = WCSession.default
        let bridge = delegateBridge ?? SessionDelegateBridge(manager: self)
        delegateBridge = bridge
        session.delegate = bridge
        session.activate()

        // A context delivered before this launch (or before the delegate was
        // attached this launch) is cached by the system and available
        // synchronously — apply it now rather than waiting for a fresh push.
        let pending = session.receivedApplicationContext
        if !pending.isEmpty {
            apply(applicationContext: pending)
        }
        isReachable = session.isReachable
    }

    /// Asks the phone for a fresh sync via an interactive message. Never
    /// throws into the UI (AGENTS.md rule 3 in spirit): when the phone isn't
    /// reachable this is simply a no-op and callers keep using whatever state
    /// they already have (synced context, or the watch's own Keychain cache).
    func requestSync() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        session.sendMessage(
            ["request": "sync"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(applicationContext: reply)
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.logger.notice("requestSync failed (phone likely went unreachable mid-flight): \(String(describing: error), privacy: .public)")
                }
            }
        )
    }

    /// Best-effort mirror of a watch-resolved approval decision back to the
    /// phone, purely so the iPhone UI can reflect "resolved from Watch"
    /// without polling. **The watch itself resolves the approval by calling
    /// the Hermes server directly** (`POST /api/approval/respond`, driven by
    /// `WatchApprovalCenter`) — this transfer is not on that critical path, is
    /// fire-and-forget, and its delivery is neither guaranteed nor time-bound
    /// (`transferUserInfo` queues and delivers opportunistically, even across
    /// an app relaunch).
    func sendApprovalDecision(sessionID: String, approvalID: String?, choice: ApprovalChoice) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        var payload: [String: Any] = [
            "type": "approval_decision",
            "session_id": sessionID,
            "choice": choice.rawValue,
            "decided_at": Date().timeIntervalSince1970
        ]
        if let approvalID {
            payload["approval_id"] = approvalID
        }
        _ = session.transferUserInfo(payload)
    }

    // MARK: - Delegate callback handling (invoked on the main actor only)

    fileprivate func handleActivationDidComplete(state: WCSessionActivationState, error: Error?) {
        if let error {
            logger.error("WCSession activation completed with error: \(String(describing: error), privacy: .public)")
        }
        isReachable = WCSession.default.isReachable
        let pending = WCSession.default.receivedApplicationContext
        if state == .activated, !pending.isEmpty {
            apply(applicationContext: pending)
        }
    }

    fileprivate func handleReachabilityChange(_ reachable: Bool) {
        isReachable = reachable
        // The moment the phone comes back in range is exactly when our synced
        // state is most likely stale, so opportunistically refresh.
        if reachable {
            requestSync()
        }
    }

    /// Applies a raw `[String: Any]` payload (from either `didReceiveApplicationContext`
    /// or a `requestSync()` reply) to `WatchServerContext`, `WatchCredentialStore`,
    /// and `recentSessions`. Every field is optional and independently tolerant —
    /// a malformed or partial payload applies whatever it can and leaves
    /// everything else untouched (AGENTS.md rule 3).
    fileprivate func apply(applicationContext context: [String: Any]) {
        defer { lastSyncedAt = Date() }

        if let signedOut = context["signed_out"] as? Bool, signedOut {
            WatchServerContext.shared.clear()
            WatchCredentialStore.shared.clear()
            Self.clearAuthCookies()
            recentSessions = []
            return
        }

        if let serverURLString = context["server_url"] as? String, !serverURLString.isEmpty {
            let displayName = context["display_name"] as? String
            // A present-but-nil `headers` key means "the phone didn't include
            // headers in this payload" (leave whatever we have), not "clear
            // them" — only an explicit, decodable string clears/replaces.
            let headers: [CustomHeader]? = (context["headers"] as? String).map { [CustomHeader].decodeFromStorage($0) }

            WatchServerContext.shared.apply(urlString: serverURLString, displayName: displayName, headers: headers)

            // Persist whatever WatchServerContext actually settled on (it may
            // have rejected an unparsable URL and kept the prior one), so the
            // local Keychain cache never drifts from the in-memory context.
            let persistedURLString = WatchServerContext.shared.baseURL?.absoluteString ?? serverURLString
            WatchCredentialStore.shared.save(
                serverURL: persistedURLString,
                displayName: WatchServerContext.shared.displayName,
                headers: CustomHeaderStore.shared.snapshot()
            )

            // The watch has no login UI: Hermes auth is a cookie the phone
            // obtained from POST /api/auth/login, and the two devices have
            // separate cookie jars. Re-inserting it into HTTPCookieStorage.shared
            // authenticates both REST (APIClient.makeDefaultSession) and SSE
            // (SSEClient's .default configuration) without any per-call plumbing.
            if let rawCookies = context["auth_cookies"] as? [[String: Any]],
               let serverURL = URL(string: persistedURLString) {
                Self.applyAuthCookies(rawCookies, serverURL: serverURL)
            }
        }

        if let sessionsData = context["sessions"] as? Data {
            if let decoded = try? JSONDecoder().decode([WatchSessionSnapshot].self, from: sessionsData) {
                recentSessions = decoded.filter { !$0.id.isEmpty }
            } else {
                logger.error("Failed to decode synced 'sessions' payload; keeping previous snapshot.")
            }
        }
    }

    /// Rebuilds `HTTPCookie`s from the phone's plist-flattened payload and stores
    /// them. Each entry is validated independently — a malformed cookie is
    /// skipped rather than failing the whole sync (AGENTS.md rule 3).
    private static func applyAuthCookies(_ entries: [[String: Any]], serverURL: URL) {
        for entry in entries {
            guard
                let name = entry["name"] as? String, !name.isEmpty,
                let value = entry["value"] as? String
            else { continue }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .path: (entry["path"] as? String) ?? "/"
            ]
            // A cookie needs either an explicit domain or an origin to anchor to.
            if let domain = entry["domain"] as? String, !domain.isEmpty {
                properties[.domain] = domain
            } else {
                properties[.originURL] = serverURL
            }
            if let isSecure = entry["secure"] as? Bool, isSecure {
                properties[.secure] = "TRUE"
            }
            // Omitting .expires yields a session cookie, which is the right
            // fallback: it lasts as long as the process rather than forever.
            if let expires = entry["expires"] as? Double {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }

            guard let cookie = HTTPCookie(properties: properties) else { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Drops every cookie this process holds. Only called on an explicit
    /// `signed_out` push — the watch talks to exactly one server at a time, so
    /// there is no other server's jar to preserve here (unlike the phone's
    /// per-server `AuthManager.clearSessionCookies(for:)`).
    private static func clearAuthCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }
}

/// `WCSessionDelegate` requires `NSObject` conformance, and every delegate
/// callback arrives on an arbitrary background queue chosen by WatchConnectivity
/// — never the main actor, and *not* implicitly `@MainActor`-isolated even
/// though `WatchConnectivityManager` is. This bridge exists solely to receive
/// those callbacks and hop onto the manager's actor via `Task { @MainActor in }`
/// before touching any of its state.
///
/// Holds an `unowned` back-reference: `WatchConnectivityManager.shared` is a
/// process-wide singleton that outlives this bridge (which the manager itself
/// owns), so the reference is always valid and `unowned` avoids a retain cycle
/// with the manager's strong `delegateBridge` property.
private final class SessionDelegateBridge: NSObject, WCSessionDelegate {
    private unowned let manager: WatchConnectivityManager

    init(manager: WatchConnectivityManager) {
        self.manager = manager
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            manager.handleActivationDidComplete(state: activationState, error: error)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            manager.apply(applicationContext: applicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            manager.handleReachabilityChange(reachable)
        }
    }

    // NOTE: `sessionDidBecomeInactive(_:)` and `sessionDidDeactivate(_:)` are
    // iOS-only (they model the iPhone's multi-watch pairing lifecycle) and are
    // not part of `WCSessionDelegate` on watchOS — intentionally omitted.
}

/// A lightweight, phone-synced projection of `SessionSummary` — just enough to
/// render `QuickSessionsView`'s rows without pulling the full model (and its
/// many optional analytics fields) across `WCSession`.
///
/// Every field but `id`/`isStreaming` is optional on the wire and decoded
/// tolerantly (AGENTS.md rule 3): a missing/malformed field degrades to `nil`/
/// `false` rather than failing the whole array. A row that decodes with no
/// usable `id` falls back to `""` here and is filtered out by the caller
/// (`WatchConnectivityManager.apply(applicationContext:)`), since an empty id
/// can't be used to open a session.
struct WatchSessionSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let workspace: String?
    let updatedAt: Date?
    let isStreaming: Bool

    init(id: String, title: String?, workspace: String?, updatedAt: Date?, isStreaming: Bool) {
        self.id = id
        self.title = title
        self.workspace = workspace
        self.updatedAt = updatedAt
        self.isStreaming = isStreaming
    }

    /// Convenience conversion from the full `SessionSummary` the phone (or a
    /// direct watch API call) already has, preferring `updatedAt` and falling
    /// back to `lastMessageAt` for the sort/staleness timestamp.
    init(_ summary: SessionSummary) {
        id = summary.sessionId ?? ""
        title = summary.title
        workspace = summary.workspace
        if let epochSeconds = summary.updatedAt ?? summary.lastMessageAt {
            updatedAt = Date(timeIntervalSince1970: epochSeconds)
        } else {
            updatedAt = nil
        }
        isStreaming = summary.isStreaming ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case workspace
        case updatedAt
        case isStreaming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        workspace = try? container.decodeIfPresent(String.self, forKey: .workspace)
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil
        isStreaming = (try? container.decodeIfPresent(Bool.self, forKey: .isStreaming)) ?? false
    }
}
