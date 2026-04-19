import SwiftUI

struct CollapsedPillView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var expanded: Bool

    var body: some View {
        Button {
            // Quick Ask has its own dedicated lifecycle — tapping the pill
            // while it's active toggles it off. Otherwise, the pill is just
            // the "expand the shell" action.
            if vm.isQuickAsking {
                vm.toggleQuickAsk()
            } else {
                withAnimation(Design.Motion.spring) {
                    expanded = true
                }
            }
        } label: {
            WaveformLogo()
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                            .opacity(vm.backgroundOpacity)
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(borderColor, lineWidth: borderWidth)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help("Open overlay")
        .animation(.easeInOut(duration: 0.2), value: vm.isDictating)
        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
    }

    private var borderColor: Color {
        if vm.isDictating    { return .orange.opacity(0.6) }
        if vm.isQuickAsking  { return .red.opacity(0.5) }
        if vm.isRecording    { return .red.opacity(0.4) }
        return .primary.opacity(0.06)
    }

    private var borderWidth: CGFloat {
        (vm.isDictating || vm.isQuickAsking || vm.isRecording) ? 1.5 : 1
    }

    private var shadowColor: Color {
        if vm.isDictating { return .orange.opacity(0.25) }
        if vm.isRecording { return .red.opacity(0.2) }
        return .black.opacity(0.12)
    }

    private var shadowRadius: CGFloat {
        (vm.isDictating || vm.isRecording) ? 10 : 6
    }
}
