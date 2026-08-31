import SwiftUI

/// Watch screen listing scheduled cron jobs ("Tasks"), with a detail view to
/// run or pause/resume each one.
struct WatchTasksView: View {
    @State private var model = WatchTasksViewModel()

    init() {}

    var body: some View {
        List {
            content
        }
        .navigationTitle("Tasks")
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.jobs.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if let errorMessage = model.errorMessage, model.jobs.isEmpty {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if model.jobs.isEmpty {
            Text("No tasks yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.jobs) { job in
                NavigationLink {
                    WatchTaskDetailView(jobID: job.id, fallback: job, model: model)
                } label: {
                    WatchTaskRow(job: job, isRunning: job.jobId.map(model.runningJobIDs.contains) ?? false)
                }
            }
        }
    }
}

/// One row: name, schedule, and a glyph for the job's current status.
private struct WatchTaskRow: View {
    let job: CronJob
    let isRunning: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.footnote)
                    .lineLimit(1)
                if let scheduleText = job.scheduleText, !scheduleText.isEmpty {
                    Text(scheduleText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isRunning {
                ProgressView()
            } else {
                statusGlyph
            }
        }
    }

    private var statusGlyph: some View {
        let (symbol, color) = statusAppearance(for: job.status)
        return Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(color)
    }

    private func statusAppearance(for status: CronJobStatus) -> (symbol: String, color: Color) {
        switch status {
        case .active:
            return ("checkmark.circle.fill", .green)
        case .paused:
            return ("pause.circle.fill", .orange)
        case .off:
            return ("circle.slash", .secondary)
        case .error:
            return ("exclamationmark.triangle.fill", .red)
        case .needsAttention:
            return ("exclamationmark.circle.fill", .yellow)
        }
    }
}

/// Detail screen for a single task: run-now, pause/resume, and the last error.
///
/// Looks the job up in `model.jobs` by id on every render (falling back to the
/// snapshot the row was pushed with) so a reload after "Run now" or
/// pause/resume is reflected here instead of showing a stale struct.
private struct WatchTaskDetailView: View {
    let jobID: String
    let fallback: CronJob
    let model: WatchTasksViewModel

    private var job: CronJob {
        model.jobs.first { $0.id == jobID } ?? fallback
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.displayName)
                    .font(.headline)

                if let scheduleText = job.scheduleText, !scheduleText.isEmpty {
                    Text(scheduleText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.run(job) }
                } label: {
                    if isRunning {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Run now")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(job.jobId == nil || isRunning)

                Button {
                    Task { await model.togglePause(job) }
                } label: {
                    Text(job.enabled == true ? "Pause" : "Resume")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(job.jobId == nil)

                if let lastError = job.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Task")
    }

    private var isRunning: Bool {
        job.jobId.map(model.runningJobIDs.contains) ?? false
    }
}
