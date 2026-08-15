import Foundation
import Observation
import OSLog

/// Process-wide, watch-side resolution of "which Hermes server are we talking to".
///
/// The watch never runs the iPhone's full `AuthManager` (596 lines of multi-server
/// registry, profile switching and cache reconciliation). It only needs three
/// things to make a request: a base URL, the custom request headers for that
/// origin, and a way to know whether we are logged in. Everything else the phone
/// owns.
///
/// Two sources feed this context, in precedence order:
///   1. `WatchConnectivityManager` — the paired iPhone pushes the active
///      `ServerAccount` + its headers over `WCSession` application context.
///   2. The watch Keychain — the last synced credentials, so a standalone
///      (phone-out-of-range) launch still works.
///
/// Tolerant by construction (AGENTS.md rule 3): a partial or unknown payload
/// leaves the previous context untouched rather than clearing it.
@MainActor
@Observable
final class WatchServerContext {
    static let shared = WatchServerContext()

    /// Normalized base URL of the active server, or `nil` before the first sync.
    private(set) var baseURL: URL?
    /// Display label for the active server (shown in the root view header).
    private(set) var displayName: String = "Hermes"
    /// Whether the last request to this server was accepted. Purely advisory —
    /// the real answer is a 401 from `APIClient`.
    private(set) var isAuthenticated: Bool = false
    /// Set when the watch has no server at all, so the UI can tell the user to
    /// open the iPhone app rather than showing an empty list.
    var needsPhoneSetup: Bool { baseURL == nil }

    private let logger = Logger(subsystem: "com.uzairansar.hermesmobile.watchkitapp", category: "ServerContext")
    private var cachedClient: APIClient?
    private var cachedClientBaseURL: URL?

    private init() {}

    /// Returns a client for the active server, reusing the last one when the base
    /// URL is unchanged. `APIClient` owns two `URLSession`s and invalidates them
    /// in `deinit`, so churning one per request would be wasteful on watchOS.
    func client() -> APIClient? {
        guard let baseURL else { return nil }
        if let cachedClient, cachedClientBaseURL == baseURL {
            return cachedClient
        }
        let client = APIClient(
            baseURL: baseURL,
            customHeaderProvider: { CustomHeaderStore.shared.snapshot() }
        )
        cachedClient = client
        cachedClientBaseURL = baseURL
        return client
    }

    /// Applies a server payload synced from the iPhone (or restored from the
    /// watch Keychain at launch). A payload with an unparsable URL is ignored so
    /// a malformed sync can't strand a working watch.
    func apply(urlString: String, displayName: String?, headers: [CustomHeader]?) {
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            logger.error("Ignoring server sync with unusable URL '\(urlString, privacy: .public)'.")
            return
        }
        if url != baseURL {
            baseURL = url
            cachedClient = nil
            cachedClientBaseURL = nil
        }
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.displayName = displayName
        }
        if let headers {
            CustomHeaderStore.shared.replace(with: headers.sanitizedForStorage())
        }
    }

    func markAuthenticated(_ value: Bool) {
        isAuthenticated = value
    }

    /// Clears the in-memory context. Called when the phone reports the user
    /// signed out. Keychain clearing is the caller's job.
    func clear() {
        baseURL = nil
        displayName = "Hermes"
        isAuthenticated = false
        cachedClient = nil
        cachedClientBaseURL = nil
    }
}

/// The four UI states of the voice interface, per WATCHOS_ARCHITECTURE_SPEC §3.1.
///
/// Deliberately a plain enum rather than a struct with flags: the orb, the
/// caption view and the haptic driver all switch exhaustively on it, so adding a
/// state is a compile error at every call site instead of a silent no-op.
enum WatchVoiceState: Equatable {
    case idle
    case listening
    /// `toolName` renders the "Running terminal…" badge from the spec.
    case thinking(toolName: String?)
    case speaking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: false
        case .listening, .thinking, .speaking: true
        }
    }
}
