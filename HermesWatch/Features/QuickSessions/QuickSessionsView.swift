import SwiftUI

/// Root watch screen: a short list of the most recently active sessions, plus
/// a way to start a brand new voice chat.
struct QuickSessionsView: View {
    @State private var model = QuickSessionsViewModel()

    init() {}

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WatchVoiceChatView(sessionID: nil, workspace: nil)
                } label: {
                    Label("New voice chat", systemImage: "plus.bubble")
                        .font(.footnote)
                }
            }

            Section {
                content
            }
        }
        .navigationTitle("Sessions")
        .task {
            await model.load()
        }
        .refreshable {
            await model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.sessions.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if let errorMessage = model.errorMessage, model.sessions.isEmpty {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if model.sessions.isEmpty {
            Text("No sessions yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.sessions) { summary in
                NavigationLink {
                    WatchVoiceChatView(sessionID: summary.sessionId, workspace: summary.workspace)
                } label: {
                    QuickSessionRow(summary: summary)
                }
            }
        }
    }
}

/// One row: title, workspace/last-activity subtitle, and a live indicator.
private struct QuickSessionRow: View {
    let summary: SessionSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                subtitle
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if summary.isStreaming == true {
                Spacer(minLength: 4)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private var title: String {
        let trimmed = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? "Untitled"
    }

    /// Workspace's last path component and a relative timestamp, joined when
    /// both are present so neither piece of context is dropped on the row.
    private var subtitle: Text {
        let workspaceName = lastPathComponent(of: summary.workspace)
        let relativeText = recencyDate.map { Text($0, style: .relative) }

        switch (workspaceName, relativeText) {
        case let (.some(name), .some(relative)):
            return Text("\(name) · ") + relative
        case let (.some(name), nil):
            return Text(name)
        case let (nil, .some(relative)):
            return relative
        case (nil, nil):
            return Text("—")
        }
    }

    private var recencyDate: Date? {
        guard let epoch = summary.lastMessageAt ?? summary.updatedAt ?? summary.createdAt else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    private func lastPathComponent(of workspace: String?) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let component = URL(fileURLWithPath: workspace).lastPathComponent
        return component.isEmpty ? nil : component
    }
}
