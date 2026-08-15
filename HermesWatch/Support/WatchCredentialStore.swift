import Foundation
import OSLog

/// Thin Keychain wrapper for the watch app's own persisted server credentials.
///
/// This is the "standalone (phone-out-of-range) launch" leg described on
/// `WatchServerContext`: the watch keeps its own last-known-good copy of the
/// active server's URL and custom headers so it can still place requests when
/// `WatchConnectivityManager` has nothing to sync yet (app relaunch, phone
/// asleep/out of Bluetooth range, etc).
///
/// ### Deliberate correction to WATCHOS_ARCHITECTURE_SPEC §4.1
/// §4.1 describes "Keychain credentials shared via Apple `kSecAttrAccessGroup` /
/// iCloud Keychain." That does not apply here: watchOS and iOS run on two
/// physically separate devices with two separate Keychains. A shared
/// `kSecAttrAccessGroup` only bridges Keychain access *within one device*
/// between an app and its extensions/widgets — it does nothing to move a secret
/// from the iPhone to the Watch. iCloud Keychain *can* sync generic passwords
/// across a user's devices, but it is opt-in, eventually-consistent, and out of
/// app control (no "sync now", no delivery confirmation) — unusable for "the
/// watch needs today's active server the moment the user picks it on the
/// phone." The actual cross-device transport this app uses is `WCSession`
/// (`WatchConnectivityManager`), which pushes an explicit application-context
/// payload and is what writes through to this store. This store's Keychain
/// service is scoped to the watch app's own bundle identifier, so it is a
/// *local cache of a synced value*, not a shared secret store.
struct WatchCredentialStore {
    static let shared = WatchCredentialStore()

    /// Logging subsystem only. The *Keychain* service is deliberately NOT this
    /// literal: `KeychainStore(service: nil)` resolves it from the Info.plist's
    /// `HermesKeychainService`, which `HermesWatch/Resources/Info.plist` sets to
    /// `$(PRODUCT_BUNDLE_IDENTIFIER)`. That way the side-by-side branch build
    /// (`…​.branch.watchkitapp`, see AGENTS.md "push to branch testflight") gets
    /// its own service name instead of colliding with production's.
    private static let loggingSubsystem = "com.uzairansar.hermesmobile.watchkitapp"

    /// `displayName` is a human-readable label (e.g. "Home Server"), not a
    /// secret, so it lives in `UserDefaults` rather than the Keychain — that
    /// keeps the Keychain payload minimal and avoids a Keychain round trip for
    /// a value the UI reads on every render of the root view's title.
    private static let displayNameDefaultsKey = "com.uzairansar.hermesmobile.watchkitapp.displayName"

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Self.loggingSubsystem, category: "CredentialStore")

    init(keychain: KeychainStore = KeychainStore(),
         defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// Persists the active server's URL, display name, and custom headers.
    /// Best-effort: a Keychain write failure is logged and swallowed rather than
    /// thrown, per AGENTS.md rule 3 — a sync hiccup must never crash the watch app.
    func save(serverURL: String, displayName: String?, headers: [CustomHeader]) {
        do {
            try keychain.save(serverURL, forKey: .serverURL)
        } catch {
            logger.error("Failed to save server URL to Keychain: \(String(describing: error), privacy: .public)")
        }

        if let encoded = headers.encodedForStorage() {
            do {
                try keychain.save(encoded, forKey: .customHeaders)
            } catch {
                logger.error("Failed to save custom headers to Keychain: \(String(describing: error), privacy: .public)")
            }
        } else {
            // No applicable headers left to store; clear any stale entry so a
            // later `load()` doesn't resurrect headers the user removed.
            try? keychain.delete(.customHeaders)
        }

        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(displayName, forKey: Self.displayNameDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.displayNameDefaultsKey)
        }
    }

    /// Loads the last-persisted server credentials, or `nil` if none are stored
    /// yet (fresh install, or the user has never paired) or the Keychain read
    /// failed. Never throws.
    func load() -> (urlString: String, displayName: String?, headers: [CustomHeader])? {
        let urlString: String?
        do {
            urlString = try keychain.load(.serverURL)
        } catch {
            logger.error("Failed to load server URL from Keychain: \(String(describing: error), privacy: .public)")
            urlString = nil
        }

        guard let urlString, !urlString.isEmpty else { return nil }

        let headersString: String?
        do {
            headersString = try keychain.load(.customHeaders)
        } catch {
            logger.error("Failed to load custom headers from Keychain: \(String(describing: error), privacy: .public)")
            headersString = nil
        }

        let headers = [CustomHeader].decodeFromStorage(headersString)
        let displayName = defaults.string(forKey: Self.displayNameDefaultsKey)
        return (urlString: urlString, displayName: displayName, headers: headers)
    }

    /// Wipes all locally stored credentials. Called when the phone reports the
    /// user signed out (`signed_out == true` in the synced application context).
    func clear() {
        try? keychain.delete(.serverURL)
        try? keychain.delete(.customHeaders)
        defaults.removeObject(forKey: Self.displayNameDefaultsKey)
    }
}
