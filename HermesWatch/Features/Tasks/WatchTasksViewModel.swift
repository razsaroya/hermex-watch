import Foundation
import Observation

/// Drives the watch's cron ("Tasks") list: run-now and pause/resume for
/// scheduled jobs on the paired server.
@MainActor
@Observable
final class WatchTasksViewModel {
    private(set) var jobs: [CronJob] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Job ids with an in-flight "run now" request, so the row can show a spinner.
    private(set) var runningJobIDs: Set<String> = []

    func load() async {
        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            jobs = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.crons()
            jobs = response.jobs ?? []
            errorMessage = nil
        } catch APIError.unauthorized {
            WatchServerContext.shared.markAuthenticated(false)
            errorMessage = "Sign in on iPhone"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ job: CronJob) async {
        guard let jobID = job.jobId else {
            errorMessage = "This task can't be run."
            return
        }
        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            return
        }

        runningJobIDs.insert(jobID)
        defer { runningJobIDs.remove(jobID) }

        do {
            _ = try await client.runCron(jobID: jobID)
            errorMessage = nil
            WatchHaptic.success.play()
            await load()
        } catch APIError.unauthorized {
            WatchServerContext.shared.markAuthenticated(false)
            errorMessage = "Sign in on iPhone"
            WatchHaptic.failure.play()
        } catch {
            errorMessage = error.localizedDescription
            WatchHaptic.failure.play()
        }
    }

    func togglePause(_ job: CronJob) async {
        guard let jobID = job.jobId else {
            errorMessage = "This task can't be changed."
            return
        }
        guard let client = WatchServerContext.shared.client() else {
            errorMessage = "No server. Open Hermex on your iPhone."
            return
        }

        do {
            if job.enabled == true {
                _ = try await client.pauseCron(jobID: jobID)
            } else {
                _ = try await client.resumeCron(jobID: jobID)
            }
            errorMessage = nil
            WatchHaptic.success.play()
            await load()
        } catch APIError.unauthorized {
            WatchServerContext.shared.markAuthenticated(false)
            errorMessage = "Sign in on iPhone"
            WatchHaptic.failure.play()
        } catch {
            errorMessage = error.localizedDescription
            WatchHaptic.failure.play()
        }
    }
}
