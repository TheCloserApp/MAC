import SwiftUI

/// Minimized chat shell: only the composer is visible, with a slim status
/// strip on top. Live updates show on the left (transcription, resume
/// progress, "thinking…"), and an expand chevron sits on the right.
struct MiniBarView: View {
    @Environment(OverlayViewModel.self) private var vm

    /// The lift handle as its own view — the composer is rendered as a
    /// separate sibling card by `OverlayContentView`, so the minimized
    /// shell uses the same two-card structure as the full shell.
    var body: some View {
        liftHandle
    }

    private var liftHandle: some View {
        HStack(spacing: 8) {
            statusBlock
            Spacer(minLength: 6)
            expandButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.025))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(Design.Motion.spring) {
                vm.isShellMinimized = false
            }
        }
    }

    private var statusBlock: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: statusText)
    }

    private var expandButton: some View {
        Button {
            withAnimation(Design.Motion.spring) {
                vm.isShellMinimized = false
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Expand")
    }

    // MARK: - Status logic

    private var statusText: String {
        // Resume generation has a granular status string the controller updates.
        if vm.isGeneratingResume, !vm.resumeGenerationStatus.isEmpty {
            return vm.resumeGenerationStatus
        }
        if vm.isScoringResume {
            return "Scoring resume…"
        }
        if vm.isSendingToAI {
            return "Thinking…"
        }
        if vm.isRecording || vm.isInterviewSession {
            let t = vm.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return String(t.suffix(120)) }
            return vm.isInterviewSession ? "Listening — speak anytime" : "Listening…"
        }
        if vm.isDictating {
            return "Dictating…"
        }
        return vm.sessionStore.activeSession.displayTitle
    }

}
