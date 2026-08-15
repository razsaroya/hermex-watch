import SwiftUI

/// Presents one pending approval with the server's full four-choice
/// vocabulary (`once` / `session` / `always` / `deny`).
///
/// The product spec's "single-tap Approve/Deny" promise is preserved for the
/// two choices reached for most often: **Approve once** and **Deny** are
/// each exactly one tap. **Approve for session** and **Always approve** are
/// additional, deliberately less prominent taps for the less common
/// escalations — so nothing the server supports is hidden from the watch,
/// while the fast path stays one tap.
struct ApprovalPromptView: View {
    let approval: PendingApproval
    let sessionID: String
    let onResolved: @MainActor (ApprovalChoice) -> Void

    init(
        approval: PendingApproval,
        sessionID: String,
        onResolved: @escaping @MainActor (ApprovalChoice) -> Void
    ) {
        self.approval = approval
        self.sessionID = sessionID
        self.onResolved = onResolved
    }

    private var center: WatchApprovalCenter { WatchApprovalCenter.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(headline)
                    .font(.footnote)

                if let command = approval.command, !command.isEmpty {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if !approval.displayPatternKeys.isEmpty {
                    patternChips
                }

                actionButtons
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Approve")
    }

    private var headline: String {
        if let description = approval.description, !description.isEmpty {
            return description
        }
        if let command = approval.command, !command.isEmpty {
            return command
        }
        return "Approval required"
    }

    private var patternChips: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(approval.displayPatternKeys, id: \.self) { key in
                Text(key)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            Button {
                respond(.once)
            } label: {
                buttonLabel("Approve once")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(center.isResponding)

            Button {
                respond(.session)
            } label: {
                buttonLabel("Approve for session")
            }
            .buttonStyle(.bordered)
            .disabled(center.isResponding)

            Button {
                respond(.always)
            } label: {
                buttonLabel("Always approve")
            }
            .buttonStyle(.bordered)
            .disabled(center.isResponding)

            Divider()

            // Deny is kept last and visually separated -- a wrist-sized
            // destructive action should never be adjacent to the approve
            // buttons where a mis-tap is easy.
            Button {
                respond(.deny)
            } label: {
                buttonLabel("Deny")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(center.isResponding)
        }
    }

    @ViewBuilder
    private func buttonLabel(_ title: String) -> some View {
        if center.isResponding {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }

    private func respond(_ choice: ApprovalChoice) {
        Task {
            await WatchApprovalCenter.shared.respond(choice)
            onResolved(choice)
        }
    }
}
