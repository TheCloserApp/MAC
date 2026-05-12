import SwiftUI

struct ModePickerView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var showModePicker: Bool
    @Binding var expanded: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SessionMode.allCases, id: \.self) { mode in
                    modeButton(for: mode)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)

                quickAskButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Design.Surface.shellFill)
                .opacity(vm.backgroundOpacity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
    }

    private func modeButton(for mode: SessionMode) -> some View {
        let selected = vm.sessionMode == mode
        return Button {
            vm.sessionMode = mode
            if mode == .interview { vm.startInterviewSession() }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                showModePicker = false
                expanded = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(mode.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selected ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(selected ? Self.color(for: mode) : Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var quickAskButton: some View {
        Button {
            vm.toggleQuickAsk()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                showModePicker = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("Quick Ask")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(vm.isQuickAsking ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(vm.isQuickAsking ? Color.red : Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private static func color(for mode: SessionMode) -> Color {
        switch mode {
        case .general:   return .purple
        case .interview: return .green
        case .meeting:   return .blue
        case .call:      return .orange
        }
    }
}
