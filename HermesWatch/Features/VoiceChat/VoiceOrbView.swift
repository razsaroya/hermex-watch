import SwiftUI

/// Circular voice-turn visualizer for the watch.
///
/// Deliberately avoids per-frame drawing (`Canvas` closures, `Timer`-driven
/// state, `TimelineView(.animation)`): every state is a small, fixed number
/// of shapes driven by at most two `@State` values, animated with
/// `withAnimation`/`.animation(value:)`. watchOS drops frames easily under a
/// real per-frame animation driver; this keeps the view cheap to keep on
/// screen for the whole voice turn.
struct VoiceOrbView: View {
    let state: WatchVoiceState
    let level: Float

    private static let diameter: CGFloat = 92

    /// Drives the `.thinking` rotating arc. Reset and restarted (via
    /// `repeatForever`) each time `state` becomes `.thinking`.
    @State private var thinkingRotation: Double = 0
    /// Drives the ambient "breathing" ring shown behind the level-reactive
    /// ring in `.listening` / `.speaking`. Reset and restarted the same way.
    @State private var ambientPulse: Bool = false

    init(state: WatchVoiceState, level: Float) {
        self.state = state
        self.level = level
    }

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
                .stroke(Color.secondary.opacity(0.4), lineWidth: 3)
            Image(systemName: "mic.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }

    private var listeningView: some View {
        let clampedLevel = clampedUnitLevel
        return ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 3)
                .scaleEffect(ambientPulse ? 1.3 : 1.05)
                .opacity(ambientPulse ? 0.15 : 0.5)
            Circle()
                .stroke(Color.accentColor, lineWidth: 4)
                .scaleEffect(1.0 + clampedLevel * 0.25)
                .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var thinkingView: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(thinkingRotation))
        }
    }

    private var speakingView: some View {
        let clampedLevel = clampedUnitLevel
        return ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                .scaleEffect(ambientPulse ? 1.25 : 1.05)
                .opacity(ambientPulse ? 0.2 : 0.5)
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                .scaleEffect(1.0 + clampedLevel * 0.18)
                .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var failedView: some View {
        ZStack {
            Circle()
                .stroke(Color.red, lineWidth: 3)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
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
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                thinkingRotation = 360
            }
        case .listening, .speaking:
            ambientPulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                ambientPulse = true
            }
        case .idle, .failed:
            break
        }
    }
}

#Preview("Idle") {
    VoiceOrbView(state: .idle, level: 0)
}

#Preview("Listening") {
    VoiceOrbView(state: .listening, level: 0.6)
}

#Preview("Thinking") {
    VoiceOrbView(state: .thinking(toolName: "terminal"), level: 0)
}

#Preview("Speaking") {
    VoiceOrbView(state: .speaking, level: 0.4)
}

#Preview("Failed") {
    VoiceOrbView(state: .failed("Sign in on iPhone"), level: 0)
}
