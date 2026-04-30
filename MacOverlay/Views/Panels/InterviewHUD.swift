import SwiftUI

/// Heads-up display that appears above the chat surface during Interview
/// mode. Shows a live recording timer + a row of quick-action chips so the
/// user can prompt the AI in one click while the interviewer's words are
/// still being transcribed.
struct InterviewHUD: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var now = Date()
    @State private var startedAt = Date()

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.md) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Interview in progress")
                    .font(Design.Font.small.weight(.semibold))
                    .foregroundColor(.primary)
                Text(formattedDuration)
                    .font(Design.Font.micro.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickActions, id: \.label) { action in
                        quickChip(action: action)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, Design.Space.lg)
        .padding(.vertical, Design.Space.sm)
        .background(
            LinearGradient(
                colors: [Color.red.opacity(0.05), Color.clear],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .onAppear { startedAt = Date() }
        .onReceive(ticker) { d in now = d }
    }

    private var formattedDuration: String {
        let secs = Int(now.timeIntervalSince(startedAt))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
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
