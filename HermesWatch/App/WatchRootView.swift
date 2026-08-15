import SwiftUI

/// Root navigation shell for the watch app (WATCHOS_ARCHITECTURE_SPEC §3: Voice,
/// Sessions, Tasks).
///
/// A single `NavigationStack` over a `List` of destinations, not a
/// `TabView(.verticalPage)`. The three surfaces here are a drill-down
/// hierarchy (pick a destination → push its detail), not peer dashboard pages
/// you'd want to swipe between — a `List` of `NavigationLink`s models that
/// directly, needs no custom page-index state, and is the smaller surface to
/// keep correct. `NavigationSplitView` is iPadOS/macOS-oriented (sidebar +
/// detail columns) and has no watchOS role here, so it's not used either.
struct WatchRootView: View {
    /// Read straight off the singletons rather than wrapping them in `@State`.
    /// `@Observable` tracking works on any property read inside `body`, so the
    /// wrapper buys nothing — and it would move the `@MainActor`-isolated
    /// `.shared` access into the view's synthesized (non-isolated) initializer,
    /// which is exactly the kind of isolation warning `SWIFT_STRICT_CONCURRENCY
    /// = targeted` flags.
    private var serverContext: WatchServerContext { WatchServerContext.shared }
    private var approvalCenter: WatchApprovalCenter { WatchApprovalCenter.shared }

    var body: some View {
        NavigationStack {
            Group {
                if serverContext.needsPhoneSetup {
                    setupPrompt
                } else {
                    destinationList
                }
            }
            .navigationTitle(serverContext.displayName)
            // watchOS 10 idiom for a NavigationStack's root background (there is
            // no `.navigationBarTitleDisplayMode` on watchOS — that modifier is
            // iOS-only and unavailable here).
            .containerBackground(.background, for: .navigation)
        }
        // Approvals must be able to interrupt any screen (spec §3.2), so this
        // sheet lives on the root stack rather than on any one destination.
        // Item-based `.sheet(item:)` over `WatchApprovalCenter.shared.pending`
        // means a *new* approval landing while the sheet is already up simply
        // re-diffs the identity and swaps the content in place — no manual
        // dismiss/re-present bookkeeping needed here.
        .sheet(item: pendingApprovalBinding) { approval in
            if let sessionID = approvalCenter.sessionID {
                // `ApprovalPromptView` already POSTs the decision to the server
                // via `WatchApprovalCenter.respond(_:)`; `onResolved` fires
                // *after* that. It must NOT respond again — doing so would
                // double-POST /api/approval/respond, and for `.always` that
                // means writing the pattern rule twice.
                //
                // What's genuinely useful here is telling the phone, so its UI
                // can show the approval as resolved-from-Watch without polling.
                ApprovalPromptView(approval: approval, sessionID: sessionID) { choice in
                    WatchConnectivityManager.shared.sendApprovalDecision(
                        sessionID: sessionID,
                        approvalID: approval.approvalId,
                        choice: choice
                    )
                }
            } else {
                // Defensive only: `WatchApprovalCenter.startWatching(sessionID:)`
                // is documented to set both together, so `pending != nil` with a
                // `nil` sessionID should never happen in practice.
                EmptyView()
            }
        }
    }

    private var destinationList: some View {
        List {
            NavigationLink {
                WatchVoiceChatView(sessionID: nil, workspace: nil)
            } label: {
                Label("Voice", systemImage: "waveform")
            }

            NavigationLink {
                QuickSessionsView()
            } label: {
                Label("Sessions", systemImage: "bubble.left.and.bubble.right")
            }

            NavigationLink {
                WatchTasksView()
            } label: {
                Label("Tasks", systemImage: "checklist")
            }
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Hermex on iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Sign in and pick a server there to sync it to your watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// Computed `Binding` over `WatchApprovalCenter.shared.pending`: reading it
    /// drives the sheet's presentation state, and writing `nil` to it (the
    /// sheet's own dismiss gesture, e.g. swipe-down) clears the prompt.
    ///
    /// This must call `dismiss()`, **not** `stopWatching()`. Swiping the sheet
    /// away means "not this one, not now" — it must not tear down the
    /// `/api/approval/stream` subscription, or the user would silently stop
    /// receiving every future approval for the session after dismissing one.
    private var pendingApprovalBinding: Binding<PendingApproval?> {
        Binding(
            get: { approvalCenter.pending },
            set: { newValue in
                if newValue == nil {
                    approvalCenter.dismiss()
                }
            }
        )
    }
}
