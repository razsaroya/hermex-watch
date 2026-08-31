import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImport?
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingNewChatRequest: NewChatRequest?
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared

    var body: some View {
        content
            .onOpenURL(perform: handleOpenURL)
            .task {
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to fire a recent run's "response complete"
                // notification, since a relaunch means it finished while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
            }
            .task {
                // Watch sync (WATCHOS_ARCHITECTURE_SPEC §4). Activating here rather
                // than in the App initializer keeps it off the launch critical path,
                // and the first sync seeds the context for a watch that launches
                // before the phone ever changes state.
                PhoneConnectivityManager.shared.activate()
                PhoneConnectivityManager.shared.sync(from: authManager)
            }
            .onChange(of: authManager.state) {
                // Covers login, logout and server switching — the state carries the
                // active server, and a fresh login means a fresh auth cookie the
                // watch needs before any of its requests will be accepted.
                PhoneConnectivityManager.shared.sync(from: authManager)
            }
            .onChange(of: authManager.servers) {
                // Renaming a server (or editing its custom headers, which are
                // persisted alongside it) changes what the watch should display
                // and send.
                PhoneConnectivityManager.shared.sync(from: authManager)
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // Re-sync on foreground: the cookie may have been refreshed or
                // expired while the app was suspended.
                PhoneConnectivityManager.shared.sync(from: authManager)
                // #248: the foreground pass stays silent — the in-session completion
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            OnboardingView(authManager: authManager)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest
            )
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same SessionListView (and
            // its server-bound view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            if let sharedImport = try HermesShareDraft.loadPendingImport(from: directory) {
                pendingSharedImport = sharedImport
            }
        } catch {
            pendingSharedImport = nil
        }
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
