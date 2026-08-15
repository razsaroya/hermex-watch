import SwiftUI

/// Root voice-chat screen for the watch: orb visualizer up top, the
/// scrollable transcript filling the middle, and a single full-width action
/// button at the bottom whose label/action follow the current turn state.
struct WatchVoiceChatView: View {
    @State private var model: WatchVoiceChatViewModel

    init(sessionID: String?, workspace: String?) {
        _model = State(initialValue: WatchVoiceChatViewModel(sessionID: sessionID, workspace: workspace))
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
