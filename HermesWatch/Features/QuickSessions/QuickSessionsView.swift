import SwiftUI

/// Root watch screen: a short list of the most recently active sessions, plus
/// a way to start a brand new voice chat.
struct QuickSessionsView: View {
    @State private var model = QuickSessionsViewModel()
    /// Selection for the "send a voice note into an existing session" swipe
    /// action below, driving `.navigationDestination(item:)`. See
    /// `VoiceNoteTarget`'s doc comment for why this is its own tiny wrapper
    /// rather than `SessionSummary` itself.
    @State private var voiceNoteTarget: VoiceNoteTarget?

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

                NavigationLink {
                    WatchVoiceNoteView(sessionID: nil, workspace: nil)
                } label: {
                    Label("New voice note", systemImage: "mic.badge.plus")
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
        .navigationDestination(item: $voiceNoteTarget) { target in
            WatchVoiceNoteView(sessionID: target.id, workspace: target.workspace)
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
                // Leading, not trailing: trailing is the conventional slot for
                // a destructive/primary action (delete, archive) that this
                // list doesn't have yet but plausibly will; leading is the
                // natural home for a non-destructive "compose into this"
                // action, the same split Mail uses (leading: flag/reply,
                // trailing: delete/archive).
                .swipeActions(edge: .leading) {
                    if let sessionID = summary.sessionId, !sessionID.isEmpty {
                        Button {
                            voiceNoteTarget = VoiceNoteTarget(sessionID: sessionID, workspace: summary.workspace)
                        } label: {
                            Label("Voice Note", systemImage: "mic.fill")
                        }
                        .tint(.accentColor)
                    }
                }
            }
        }
    }
}

/// Minimal, value-stable identity for "which session to open a voice note
/// against" — the `navigationDestination(item:)` selection the swipe action
/// above sets.
///
/// `SessionSummary` (HermesMobile/Models/Session.swift) already conforms to
/// `Hashable & Identifiable`, so it could technically be used as the item
/// directly without this wrapper. It deliberately isn't: `SessionSummary`'s
/// `Hashable` conformance is synthesized over *all* its stored properties,
/// including several `.refreshable` above can change on any poll
/// (`messageCount`, `isStreaming`, `lastMessageAt`, `estimatedCost`, …).
/// `navigationDestination(item:)` ties the destination's identity to the
/// item's value; a `@State` selection is a snapshot copy so an in-place list
/// refresh can't retroactively change *this* selection, but keying that
/// selection off a struct whose equality is entangled with unrelated,
/// frequently-changing metadata is still the wrong contract to lean on here
/// — the destination only ever cares about *which session and workspace*,
/// nothing else `SessionSummary` carries. A narrow wrapper keyed on exactly
/// `sessionId` + `workspace` says that directly and stays correct regardless
/// of what fields `SessionSummary` gains later.
private struct VoiceNoteTarget: Identifiable, Hashable {
    let id: String
    let workspace: String?

    init(sessionID: String, workspace: String?) {
        self.id = sessionID
        self.workspace = workspace
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
