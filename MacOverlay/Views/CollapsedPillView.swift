import SwiftUI

/// The small pill visible when the shell is collapsed. Rendered as the same
/// 36×36 glass cell the sidebar uses for its close button — so when the user
/// clicks to expand, the X cell lands on the exact same screen pixels the
/// waveform was occupying. Transition feels like the waveform morphs into an
/// X and the sidebar + panels grow out from around it.
struct CollapsedPillView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Button {
            if vm.isQuickAsking {
                vm.toggleQuickAsk()
            } else {
                withAnimation(Design.Motion.spring) {
                    vm.isShellExpanded = true
                }
            }
        } label: {
            WaveformLogo()
                .frame(width: 36, height: 36)
                .glassCard(cornerRadius: 12, shadow: Design.Shadow.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(recordingBorder, lineWidth: recordingBorder == .clear ? 0 : 1.5)
                }
        }
        .buttonStyle(.plain)
        .help("Open overlay")
    }

    private var recordingBorder: Color {
        if vm.isDictating    { return .orange.opacity(0.6) }
        if vm.isQuickAsking  { return .red.opacity(0.5) }
        if vm.isRecording    { return .red.opacity(0.45) }
        return .clear
    }
}
