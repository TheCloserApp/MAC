import SwiftUI

/// Slim quick-action row that appears above the chat surface during
/// Interview mode. The old "Interview in progress" + duration header was
/// removed because it ate vertical space without adding much; the live
/// timer now lives inline on the transcript strip (see `ChatSurfaceView
/// .liveTranscriptStrip`), and this view just hosts one-tap prompts.
struct InterviewHUD: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickActions, id: \.label) { action in
                    quickChip(action: action)
                }
            }
            .padding(.horizontal, Design.Space.lg)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Quick actions

    private struct QuickAction: Hashable {
        let label: String
        let icon: String
        let prompt: String
    }

    private let quickActions: [QuickAction] = [
        QuickAction(label: "STAR answer",    icon: "star",
                    prompt: "Give me a strong STAR-format answer for the interviewer's last question, based on the transcription so far."),
        QuickAction(label: "Key points",     icon: "list.bullet",
                    prompt: "Extract the key points the interviewer just mentioned, in concise bullets."),
        QuickAction(label: "Follow-up",      icon: "arrow.up.forward",
                    prompt: "Suggest one thoughtful follow-up question I can ask the interviewer right now."),
        QuickAction(label: "Clarify term",   icon: "questionmark.circle",
                    prompt: "Any technical term in the last exchange I should ask the interviewer to clarify? If so, phrase the clarification politely."),
        QuickAction(label: "Summarise",      icon: "sparkles",
                    prompt: "Summarise the interview so far in 4 bullets — topics covered, strengths I've shown, and anything I should double-back on."),
    ]

    private func quickChip(action: QuickAction) -> some View {
        Button {
            // Prefill the manual input and send on the next tick so the
            // user sees the bubble appear immediately.
            vm.showManualInput = true
            vm.manualInput = action.prompt
            vm.sendToAI()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.system(size: 10))
                Text(action.label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(action.prompt)
    }
}
