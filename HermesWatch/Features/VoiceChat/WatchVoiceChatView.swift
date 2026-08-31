import SwiftUI

/// Root voice-chat screen for the watch: orb visualizer up top, the
/// scrollable transcript filling the middle, and a single full-width action
/// button at the bottom whose label/action follow the current turn state.
struct WatchVoiceChatView: View {
    @State private var model: WatchVoiceChatViewModel
    /// `WatchVoiceChatViewModel` only exposes the *session* id, not the
    /// workspace it was created with (it has no reason to — it never hands
    /// that back to anything). The "send a voice note into this session"
    /// toolbar link below needs it to construct `WatchVoiceNoteView` with the
    /// same workspace this screen is scoped to, so it's kept here instead.
    private let workspace: String?

    init(sessionID: String?, workspace: String?) {
        _model = State(initialValue: WatchVoiceChatViewModel(sessionID: sessionID, workspace: workspace))
        self.workspace = workspace
    }

    var body: some View {
        VStack(spacing: 8) {
            VoiceOrbView(state: model.state, level: model.level)
                .padding(.top, 2)

            StreamingCaptionView(
                userTranscript: model.transcript,
                assistantText: model.assistantText,
                toolName: model.activeToolName
            )
            .frame(maxHeight: .infinity)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            actionButton
        }
        .padding(.horizontal, 4)
        .navigationTitle("Voice")
        .task {
            await model.onAppear()
        }
        .onDisappear {
            model.onDisappear()
        }
        .toolbar {
            // Gated on both conditions: `sessionID` stays nil until the first
            // turn's lazy `createSession()` call succeeds (see
            // `WatchVoiceChatViewModel.runTurn`), so there is no session yet
            // to attach a voice note to before that; and `!state.isBusy`
            // keeps a voice note from firing into a session that has a turn
            // in flight, which would race that turn's own use of the session
            // (overlapping SSE streams, confusing message ordering) for no
            // benefit — the user can just wait the few seconds for the
            // current turn to land.
            if !model.state.isBusy, let sessionID = model.sessionID {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchVoiceNoteView(sessionID: sessionID, workspace: workspace)
                    } label: {
                        Image(systemName: "mic.badge.plus")
                    }
                    .accessibilityLabel("Send voice note")
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch model.state {
        case .idle, .failed:
            actionButtonLabel("Speak", systemImage: "mic.fill", tint: .accentColor) {
                await model.toggleMicrophone()
            }
        case .listening:
            actionButtonLabel("Stop", systemImage: "stop.fill", tint: .red) {
                await model.toggleMicrophone()
            }
        case .thinking, .speaking:
            actionButtonLabel("Cancel", systemImage: "xmark", tint: .gray) {
                await model.cancelCurrentTurn()
            }
        }
    }

    private func actionButtonLabel(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}

#Preview {
    WatchVoiceChatView(sessionID: nil, workspace: nil)
}
