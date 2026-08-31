import SwiftUI

/// Live voice screen for iOS (Hermex iPhone)
struct LiveVoiceChatView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: LiveVoiceChatViewModel

    init(session: SessionSummary, server: URL) {
        _model = State(initialValue: LiveVoiceChatViewModel(session: session, server: server))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VoiceOrbView(state: model.state, level: model.level)
                    .frame(height: 180)

                statusBadge

                StreamingCaptionView(
                    userTranscript: model.transcript,
                    assistantText: model.assistantText,
                    toolName: model.activeToolName
                )
                .frame(maxHeight: 220)
                .padding(.horizontal, 16)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                controlsSection
            }
            .padding(.bottom, 24)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(String(localized: "Live Voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isAutoListenEnabled.toggle()
                    } label: {
                        Label(
                            "Auto",
                            systemImage: model.isAutoListenEnabled ? "repeat.circle.fill" : "repeat.circle"
                        )
                        .foregroundStyle(model.isAutoListenEnabled ? Color.accentColor : Color.secondary)
                    }
                }
            }
            .task {
                await model.onAppear()
            }
            .onDisappear {
                model.onDisappear()
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.state {
        case .idle:
            Text(String(localized: "Tap the microphone to speak"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .listening:
            Text(String(localized: "Listening..."))
                .font(.subheadline.bold())
                .foregroundStyle(Color.accentColor)
        case .thinking(let toolName):
            if let toolName, !toolName.isEmpty {
                Text(String(localized: "Running \(toolName)..."))
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            } else {
                Text(String(localized: "Thinking..."))
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
        case .speaking:
            Text(String(localized: "Speaking..."))
                .font(.subheadline.bold())
                .foregroundStyle(Color.accentColor)
        case .failed:
            Text(String(localized: "Turn failed"))
                .font(.subheadline.bold())
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        HStack(spacing: 32) {
            switch model.state {
            case .idle, .failed:
                Button {
                    Task { await model.toggleMicrophone() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.accentColor, in: Circle())
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)
                }

            case .listening:
                Button {
                    Task { await model.toggleMicrophone() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.red, in: Circle())
                        .shadow(color: Color.red.opacity(0.3), radius: 8, y: 4)
                }

            case .thinking, .speaking:
                Button {
                    model.cancelCurrentTurn()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.gray, in: Circle())
                        .shadow(color: Color.gray.opacity(0.3), radius: 8, y: 4)
                }
            }
        }
    }
}

struct VoiceOrbView: View {
    let state: LiveVoiceState
    let level: Float

    private static let diameter: CGFloat = 140

    @State private var thinkingRotation: Double = 0
    @State private var ambientPulse: Bool = false

    var body: some View {
        content
            .frame(width: Self.diameter, height: Self.diameter)
            .onAppear { syncContinuousAnimations() }
            .onChange(of: state) { _, _ in syncContinuousAnimations() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleView
        case .listening:
            listeningView
        case .thinking:
            thinkingView
        case .speaking:
            speakingView
        case .failed:
            failedView
        }
    }

    private var idleView: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
            Circle()
                .fill(Color.secondary.opacity(0.08))
            Image(systemName: "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }

    private var listeningView: some View {
        let clampedLevel = clampedUnitLevel
        return ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 4)
                .scaleEffect(ambientPulse ? 1.35 : 1.05)
                .opacity(ambientPulse ? 0.1 : 0.6)
            Circle()
                .stroke(Color.accentColor, lineWidth: 5)
                .scaleEffect(1.0 + clampedLevel * 0.3)
                .animation(.easeOut(duration: 0.1), value: level)
            Circle()
                .fill(Color.accentColor.opacity(0.12))
            Image(systemName: "waveform")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var thinkingView: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(thinkingRotation))
            Circle()
                .fill(Color.accentColor.opacity(0.05))
        }
    }

    private var speakingView: some View {
        let clampedLevel = clampedUnitLevel
        return ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 4)
                .scaleEffect(ambientPulse ? 1.3 : 1.05)
                .opacity(ambientPulse ? 0.15 : 0.5)
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 4)
                .scaleEffect(1.0 + clampedLevel * 0.25)
                .animation(.easeOut(duration: 0.1), value: level)
            Circle()
                .fill(Color.accentColor.opacity(0.1))
            Image(systemName: "waveform")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var failedView: some View {
        ZStack {
            Circle()
                .stroke(Color.red, lineWidth: 4)
            Circle()
                .fill(Color.red.opacity(0.1))
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.red)
        }
    }

    private var clampedUnitLevel: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    private func syncContinuousAnimations() {
        switch state {
        case .thinking:
            thinkingRotation = 0
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                thinkingRotation = 360
            }
            ambientPulse = false
        case .listening, .speaking:
            ambientPulse = false
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                ambientPulse = true
            }
            thinkingRotation = 0
        case .idle, .failed:
            ambientPulse = false
            thinkingRotation = 0
        }
    }
}

struct StreamingCaptionView: View {
    let userTranscript: String
    let assistantText: String
    let toolName: String?

    private enum AnchorID {
        static let bottom = "streamingCaptionBottom"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !userTranscript.isEmpty {
                        userLine
                    }
                    if !assistantText.isEmpty {
                        Text(assistantText)
                            .font(.body)
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
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
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
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(userTranscript)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolBadge(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hammer.fill")
                .font(.caption)
            Text(String(localized: "Running \(name)..."))
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(AnchorID.bottom, anchor: .bottom)
        }
    }
}
