import Foundation
import Observation

/// Process-wide watch approval prompt: watches a session's approval stream
/// and surfaces the single most recent pending approval so any screen can
/// show `ApprovalPromptView` for it.
///
/// `present(_:sessionID:)` is the only mutation entry point — `pending` and
/// `sessionID` are `private(set)` so the voice-chat feature (and this
/// center's own SSE/poll handlers) can only push a new prompt through the
/// same, haptic-aware path.
@MainActor
@Observable
final class WatchApprovalCenter {
    static let shared = WatchApprovalCenter()

    private(set) var pending: PendingApproval?
    private(set) var sessionID: String?
    private(set) var isResponding = false
    private(set) var errorMessage: String?

    var hasPendingApproval: Bool { pending != nil }

    private var sseClient: SSEClient?
    private var initialFetchTask: Task<Void, Never>?
    /// The last approval id we buzzed for, so a repeat delivery of the same
    /// approval (SSE re-send, or the initial fetch racing the stream) doesn't
    /// re-trigger the haptic.
    private var lastNotifiedApprovalID: String?

    private init() {}

    /// Publishes a new pending approval for `sessionID`. Buzzes
    /// `.notification` only when `approval.id` differs from the last one we
    /// already surfaced.
    func present(_ approval: PendingApproval, sessionID: String) {
        self.sessionID = sessionID

        guard !approval.isEmpty else {
            pending = nil
            return
        }

        let isNewApproval = approval.id != lastNotifiedApprovalID
        pending = approval
        if isNewApproval {
            lastNotifiedApprovalID = approval.id
            WatchHaptic.notification.play()
        }
        // Surface it on the watch face too — an approval the user hasn't opened
        // the app to see is exactly what a complication is for (§3.2/§4).
        WatchStatusPublisher.shared.setPendingApprovalCount(1)
    }

    /// Opens the SSE approval stream for `sessionID` and, in parallel, fires
    /// an immediate `approvalPending` fetch so an approval raised before the
    /// stream connected is not missed (SSE only pushes future events).
    func startWatching(sessionID: String) {
        stopWatching()
        self.sessionID = sessionID
        errorMessage = nil

        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            return
        }

        initialFetchTask = Task { [weak self] in
            guard let self else { return }
            guard let response = try? await client.approvalPending(sessionID: sessionID) else {
                return
            }
            self.handle(response, sessionID: sessionID)
        }

        let stream = SSEClient()
        sseClient = stream
        let url = client.approvalStreamURL(sessionID: sessionID)
        stream.start(url: url) { [weak self] event in
            self?.handle(event, sessionID: sessionID)
        }
    }

    /// Stops the SSE stream and cancels the initial fetch. Safe to call
    /// repeatedly (e.g. from both `onDisappear` and a subsequent
    /// `startWatching`).
    func stopWatching() {
        sseClient?.stop()
        sseClient = nil
        initialFetchTask?.cancel()
        initialFetchTask = nil
    }

    /// Clears the current prompt without responding to the server (e.g. the
    /// user navigated away). Does not stop the stream.
    func dismiss() {
        pending = nil
    }

    func respond(_ choice: ApprovalChoice) async {
        guard let sessionID else {
            errorMessage = "No active session."
            return
        }
        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            return
        }

        isResponding = true
        defer { isResponding = false }

        do {
            let response = try await client.respondApproval(
                sessionID: sessionID,
                choice: choice,
                approvalID: pending?.approvalId
            )

            // `stale`/`staleCleared` mean the server already resolved (or
            // dropped) this approval elsewhere -- most likely the phone beat
            // us to it. That is a benign outcome, not a failure: there is
            // nothing left to approve, so the prompt still clears and we
            // still treat it as success rather than leaving a dead prompt on
            // the wrist.
            let isBenignStale = response.stale == true || response.staleCleared == true
            if response.ok == false, !isBenignStale {
                errorMessage = "Approval response failed."
                WatchHaptic.failure.play()
                return
            }

            errorMessage = nil
            pending = nil
            lastNotifiedApprovalID = nil
            WatchStatusPublisher.shared.setPendingApprovalCount(0)
            WatchHaptic.success.play()
        } catch APIError.unauthorized {
            WatchServerContext.shared.markAuthenticated(false)
            errorMessage = "Sign in on iPhone"
            WatchHaptic.failure.play()
        } catch {
            errorMessage = error.localizedDescription
            WatchHaptic.failure.play()
        }
    }

    private func handle(_ event: SSEEvent, sessionID: String) {
        switch event {
        case .approvalPending(let response):
            handle(response, sessionID: sessionID)
        case .error(let message), .transportError(let message):
            errorMessage = message
        case .heartbeat, .streamEnd, .ignored:
            break
        default:
            // Every other event belongs to a chat/token stream, not the
            // approval stream; ignore rather than guessing at handling.
            break
        }
    }

    private func handle(_ response: ApprovalPendingResponse, sessionID: String) {
        guard let approval = response.pending, !approval.isEmpty else {
            // An explicit `pending_count: 0` is the server telling us the
            // approval was resolved somewhere else — most often the user tapped
            // Approve on their phone. Clear the wrist prompt so it doesn't sit
            // there demanding a decision that has already been made.
            //
            // Only an *explicit* zero counts. `ApprovalPendingResponse.streamPayload`
            // also yields `(pending: nil, pendingCount: nil)` for a payload it
            // couldn't parse, and a malformed frame must never silently dismiss
            // a real approval.
            if response.pendingCount == 0 {
                pending = nil
                lastNotifiedApprovalID = nil
                WatchStatusPublisher.shared.setPendingApprovalCount(0)
            }
            return
        }
        present(approval, sessionID: sessionID)
    }
}
