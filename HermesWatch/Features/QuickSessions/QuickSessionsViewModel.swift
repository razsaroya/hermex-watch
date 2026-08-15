import Foundation
import Observation

/// Drives the watch's session list: the 15 most recently active sessions on
/// the paired server, newest first.
///
/// A watch list of the full session history (which can run into the hundreds
/// on an active server) is both useless on a 40mm screen and a needless
/// memory/decoding cost, so `load()` caps the result at the 15 most recent
/// sessions after sorting.
@MainActor
@Observable
final class QuickSessionsViewModel {
    /// Most-recent-first, capped at 15 (see type doc).
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Sessions beyond this rank are dropped after sorting.
    private static let maxSessions = 15

    func load() async {
        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            sessions = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.sessions()
            sessions = Self.sorted(response.sessions ?? [])
            errorMessage = nil
        } catch APIError.unauthorized {
            WatchServerContext.shared.markAuthenticated(false)
            errorMessage = "Sign in on iPhone"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        await load()
    }

    /// Sorts by the most recent of `lastMessageAt`, `updatedAt`, `createdAt`
    /// (in that preference order), descending, then caps at `maxSessions`.
    private static func sorted(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let ranked = sessions.sorted { lhs, rhs in
            recencyKey(lhs) > recencyKey(rhs)
        }
        return Array(ranked.prefix(maxSessions))
    }

    private static func recencyKey(_ session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }
}
