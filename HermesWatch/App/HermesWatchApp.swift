import SwiftUI

/// Entry point for the `HermesWatch` target (watchOS 10+), per
/// WATCHOS_ARCHITECTURE_SPEC §2 (target structure) and §5 Phase 2/3.
///
/// watchOS has no `UIApplicationDelegateAdaptor` and no app-launch-time work
/// that genuinely needs `WKApplicationDelegateAdaptor` here (no background
/// task scheduling, no complication push handling in this slice) — everything
/// this launch sequence needs (activating `WCSession`, restoring the last
/// synced server) is plain `@State`/`.task` work on the root scene, so that
/// extra delegate type is deliberately not introduced.
@main
struct HermesWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .task {
                    restoreCredentialsIfNeeded()
                    WatchConnectivityManager.shared.activate()
                }
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            // Coming to the foreground (wrist raise, app switch back, etc.) is
            // the highest-value moment to ask the phone for a fresh sync: the
            // user is about to look at whatever we render, and this is
            // exactly when a stale "no server" or stale session list would be
            // most visible. `requestSync()` is a documented no-op when the
            // phone isn't reachable, so this is always safe to call.
            WatchConnectivityManager.shared.requestSync()
        }
    }

    /// Seeds `WatchServerContext` from the watch's own Keychain cache before
    /// `WatchConnectivityManager` has a chance to deliver anything fresh, so a
    /// cold launch with the phone out of range still shows the last-known
    /// server instead of the "Open Hermex on iPhone" empty state. A later,
    /// fresher sync (via `activate()`'s cached-context replay or
    /// `requestSync()`) simply overwrites this.
    private func restoreCredentialsIfNeeded() {
        guard WatchServerContext.shared.baseURL == nil else { return }
        guard let saved = WatchCredentialStore.shared.load() else { return }
        WatchServerContext.shared.apply(
            urlString: saved.urlString,
            displayName: saved.displayName,
            headers: saved.headers
        )
    }
}
