import Foundation
import Observation
import OSLog
import WatchConnectivity

/// iPhone half of the Watch sync described in WATCHOS_ARCHITECTURE_SPEC §4
/// ("WatchConnectivity (Phone Pairing Sync)"). Pushes the active server — and
/// the session cookie that authenticates it — to `HermesWatch`, which has no
/// login UI of its own.
///
/// ### Wire format
/// Owned jointly with `HermesWatch/Connectivity/WatchConnectivityManager.swift`;
/// that file documents the same dictionary from the receiving side. Keep the two
/// in sync when changing a key.
/// ```
/// [
///   "server_url":   String,          // active server's base URL
///   "display_name": String?,         // ServerAccount.displayName
///   "headers":      String?,         // [CustomHeader].encodedForStorage() JSON
///   "auth_cookies": [[String: Any]]?,// session cookies scoped to server_url
///   "signed_out":   Bool?            // true => user signed out on the phone
/// ]
/// ```
///
/// ### Why cookies travel too
/// The watch builds an `APIClient` from a base URL plus custom headers and has
/// no password field. Hermes auth is an HMAC-signed HTTP-only cookie set by
/// `POST /api/auth/login` (PROJECT_SPEC.md §Auth), and that cookie lives in the
/// *phone's* `HTTPCookieStorage`. A watch and an iPhone are separate devices
/// with separate cookie jars, so without shipping the cookie across, every watch
/// request to a password-protected server returns 401 and the watch app is inert.
/// `APIClient.makeDefaultSession` and `SSEClient` both use
/// `HTTPCookieStorage.shared`, so re-inserting the cookie on the watch
/// authenticates REST and SSE alike with no per-call plumbing.
///
/// Only cookies `HTTPCookieStorage.cookies(for:)` would already send to the
/// active server are included — the same host/path/security matching
/// `AuthManager.clearSessionCookies(for:)` uses — so a multi-server user never
/// leaks one server's cookie to another.
@MainActor
@Observable
final class PhoneConnectivityManager {
    static let shared = PhoneConnectivityManager()

    /// Whether a paired watch currently has the watch app installed. Purely
    /// advisory — used to skip pointless context pushes, never to gate features.
    private(set) var isWatchAppInstalled: Bool = false
    /// When the last application context was accepted by the system. Note this
    /// is *queued*, not delivered: WatchConnectivity decides when the watch
    /// actually receives it.
    private(set) var lastSyncedAt: Date?

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "Connectivity")
    /// `WCSession.delegate` is `weak`, so this must be owned here or every
    /// callback silently stops after `activate()` returns.
    private var delegateBridge: SessionDelegateBridge?
    /// Last payload built, replayed verbatim when the watch asks for a fresh
    /// sync via `sendMessage(["request": "sync"])`.
    private var latestPayload: [String: Any] = [:]
    /// Guards against re-pushing an identical context on every incidental
    /// `@Observable` change; `updateApplicationContext` is cheap but not free,
    /// and each call wakes the watch app.
    private var lastPushedFingerprint: String?

    private init() {}

    /// Activates the session for this process. Safe to call repeatedly.
    func activate() {
        guard WCSession.isSupported() else {
            logger.notice("WCSession unsupported on this device; watch sync disabled.")
            return
        }
        let session = WCSession.default
        let bridge = delegateBridge ?? SessionDelegateBridge(manager: self)
        delegateBridge = bridge
        session.delegate = bridge
        session.activate()
        isWatchAppInstalled = session.isPaired && session.isWatchAppInstalled
    }

    /// Builds the current payload and pushes it to the watch. Call on any change
    /// to the active server, the server list, or the custom headers.
    ///
    /// Never throws into the caller: an unreachable or watch-less phone is the
    /// normal case, not an error (AGENTS.md rule 3 in spirit).
    func sync(from authManager: AuthManager) {
        guard WCSession.isSupported() else { return }
        let payload = makePayload(from: authManager)
        latestPayload = payload

        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let fingerprint = Self.fingerprint(of: payload)
        guard fingerprint != lastPushedFingerprint else { return }

        do {
            try session.updateApplicationContext(payload)
            lastPushedFingerprint = fingerprint
            lastSyncedAt = Date()
        } catch {
            // Most commonly WCErrorCodeNotPaired / a transient session error.
            logger.error("updateApplicationContext failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Payload

    private func makePayload(from authManager: AuthManager) -> [String: Any] {
        guard let server = authManager.state.server else {
            // `.unconfigured` is the only state with no server: the user signed
            // out or never configured one. Tell the watch explicitly so it can
            // clear its own Keychain cache rather than serving stale credentials.
            return ["signed_out": true]
        }

        var payload: [String: Any] = ["server_url": server.absoluteString]

        // ServerAccount.id is the absolute URL string (see AuthManager.activeServerID).
        if let account = authManager.servers.first(where: { $0.id == server.absoluteString }) {
            payload["display_name"] = account.displayName
        }
        if let encodedHeaders = CustomHeaderStore.shared.snapshot().encodedForStorage() {
            payload["headers"] = encodedHeaders
        }
        let cookies = Self.authCookiePayload(for: server)
        if !cookies.isEmpty {
            payload["auth_cookies"] = cookies
        }
        return payload
    }

    /// Flattens the cookies for `server` into plist-safe dictionaries.
    /// `updateApplicationContext` rejects anything that isn't a property-list
    /// type, so `Date` becomes a `Double` and `HTTPCookiePropertyKey` becomes a
    /// plain `String`; the watch rebuilds `HTTPCookie` from these.
    private static func authCookiePayload(for server: URL) -> [[String: Any]] {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: server) else { return [] }
        return cookies.map { cookie in
            var entry: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure
            ]
            if let expiresDate = cookie.expiresDate {
                entry["expires"] = expiresDate.timeIntervalSince1970
            }
            return entry
        }
    }

    /// Order-independent digest of the payload, so re-running `sync` with
    /// unchanged state doesn't wake the watch. Cookie *values* are included:
    /// a re-login issues a new cookie that must reach the watch.
    private static func fingerprint(of payload: [String: Any]) -> String {
        func describe(_ value: Any) -> String {
            switch value {
            case let dict as [String: Any]:
                return "{" + dict.keys.sorted().map { "\($0)=\(describe(dict[$0]!))" }.joined(separator: ",") + "}"
            case let array as [[String: Any]]:
                return "[" + array.map(describe).joined(separator: ",") + "]"
            default:
                return String(describing: value)
            }
        }
        return describe(payload)
    }

    // MARK: - Delegate callbacks (main actor only)

    fileprivate func handleWatchStateChange() {
        let session = WCSession.default
        isWatchAppInstalled = session.isPaired && session.isWatchAppInstalled
        // A freshly installed watch app has never seen a context — force the
        // next sync to push even if the payload is byte-identical.
        lastPushedFingerprint = nil
    }

    fileprivate func replyPayload() -> [String: Any] {
        latestPayload
    }

    fileprivate func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

/// `WCSessionDelegate` requires `NSObject`, and its callbacks arrive on an
/// arbitrary background queue — never the main actor — so this bridge hops onto
/// the manager's actor before touching any state. Mirrors the watch side's
/// bridge of the same name.
///
/// `unowned` back-reference: the manager is a process-wide singleton that owns
/// this bridge and outlives it, so this can never dangle, and it avoids a cycle.
private final class SessionDelegateBridge: NSObject, WCSessionDelegate {
    private unowned let manager: PhoneConnectivityManager

    init(manager: PhoneConnectivityManager) {
        self.manager = manager
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let description = error.map { String(describing: $0) }
        Task { @MainActor in
            if let description {
                manager.log("WCSession activation error: \(description)")
            }
            manager.handleWatchStateChange()
        }
    }

    /// The watch asked for a fresh sync (it just launched, or the phone came
    /// back in range). Reply with the same shape as the application context —
    /// `WatchConnectivityManager` funnels both through one `apply` path.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["request"] as? String == "sync" else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            replyHandler(manager.replyPayload())
        }
    }

    /// The watch resolved an approval on-wrist and is telling us after the fact.
    /// The watch already called the server itself, so there is nothing to do
    /// beyond logging — kept so the transfer isn't silently dropped, and as the
    /// hook point for reflecting "resolved from Watch" in the iPhone UI later.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["type"] as? String == "approval_decision" else { return }
        let sessionID = userInfo["session_id"] as? String ?? "unknown"
        let choice = userInfo["choice"] as? String ?? "unknown"
        Task { @MainActor in
            manager.log("Watch resolved approval for session \(sessionID) as \(choice).")
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            manager.handleWatchStateChange()
        }
    }

    // MARK: iOS-only lifecycle (absent from WCSessionDelegate on watchOS)

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required for multi-watch support: when the user switches paired watches
    /// the old session deactivates and we must re-activate to bind to the new
    /// one, or all further syncs go nowhere.
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
