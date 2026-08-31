import SwiftUI

/// Scrollable running transcript for the current voice turn: the user's
/// transcribed utterance, the assistant's streaming reply, and a compact
/// "Running <tool>…" badge while a tool call is in flight.
///
/// Watch screens can't fit much text at once, so this always lives in a
/// `ScrollView` and auto-scrolls to the newest content as it streams in
/// (the Digital Crown remains free to scroll back up).
struct StreamingCaptionView: View {
    let userTranscript: String
    let assistantText: String
    let toolName: String?

    init(userTranscript: String, assistantText: String, toolName: String?) {
        self.userTranscript = userTranscript
        self.assistantText = assistantText
        self.toolName = toolName
    }

    private enum AnchorID {
        static let bottom = "streamingCaptionBottom"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !userTranscript.isEmpty {
                        userLine
                    }
                    if !assistantText.isEmpty {
                        Text(assistantText)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let toolName, !toolName.isEmpty {
                        toolBadge(toolName)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(AnchorID.bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: assistantText) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: toolName) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var userLine: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "person.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(userTranscript)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolBadge(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer.fill")
                .font(.caption2)
            Text("Running \(name)…")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.2), in: Capsule())
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(AnchorID.bottom, anchor: .bottom)
        }
    }
}

#Preview {
    StreamingCaptionView(
        userTranscript: "What's the weather like today?",
        assistantText: "Let me check that for you.",
        toolName: "terminal"
    )
}

#Preview("No tool") {
    StreamingCaptionView(
        userTranscript: "Summarize the README",
        assistantText: "The README describes a self-hosted chat server with a SwiftUI iPhone client.",
        toolName: nil
    )
}
