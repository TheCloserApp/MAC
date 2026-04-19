import SwiftUI

/// Vertical column of separate glass pills. Each cell floats independently
/// with a visible gap from its neighbours. The top cell is the brand/close
/// toggle — when expanded it reads as X (collapse), when collapsed it's the
/// waveform logo.
struct SidebarView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: Design.cardGap) {
            closeCell
            WorkspaceSwitcherView()
                .frame(width: 36, height: 36)
                .glassCard(cornerRadius: 12, shadow: Design.Shadow.card)
            newSessionCell

            surfaceCell(.chat,     icon: "bubble.left.and.bubble.right",
                        activeIcon: "bubble.left.and.bubble.right.fill", tooltip: "Session")
            surfaceCell(.sessions, icon: "clock.arrow.circlepath",
                        activeIcon: "clock.arrow.circlepath",            tooltip: "History")
            surfaceCell(.prompts,  icon: "text.bubble",
                        activeIcon: "text.bubble.fill",                  tooltip: "Prompts")
            surfaceCell(.resumes,  icon: "doc.text",
                        activeIcon: "doc.text.fill",                     tooltip: "Resumes")
            surfaceCell(.calendar, icon: "calendar",
                        activeIcon: "calendar",                          tooltip: "Calendar")
            surfaceCell(.browser,  icon: "globe",
                        activeIcon: "globe",                             tooltip: "Browser")

            Spacer()

            preferencesCell
        }
        .frame(width: 44)
    }

    // MARK: - Cells

    /// Brand-or-close cell. Expanded: X (click collapses). Collapsed: waveform.
    private var closeCell: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                expanded = false
            }
        } label: {
            ZStack {
                if expanded {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.75))
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                } else {
                    WaveformLogo()
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 12, shadow: Design.Shadow.card)
        .help("Collapse to pill")
        .animation(Design.Motion.pop, value: expanded)
    }

    private var newSessionCell: some View {
        Button { vm.startNewSession() } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                .designShadow(Design.Shadow.card)
        }
        .buttonStyle(.plain)
        .help("New session (⌘N)")
    }

    private var preferencesCell: some View {
        Button {
            PreferencesWindowController.shared.show(vm: vm)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(vm.needsKeyForCurrentModel ? .orange : .primary.opacity(0.7))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 12, shadow: Design.Shadow.card)
        .help("Preferences (⌘,)")
    }

    @ViewBuilder
    private func surfaceCell(_ surface: OverlayViewModel.PrimarySurface,
                             icon: String,
                             activeIcon: String,
                             tooltip: String) -> some View {
        let active = vm.primarySurface == surface
        let label = Image(systemName: active ? activeIcon : icon)
            .font(.system(size: 14, weight: active ? .semibold : .regular))
            .foregroundColor(active ? .white : .primary.opacity(0.75))
            .frame(width: 36, height: 36)

        Button {
            withAnimation(Design.Motion.pop) {
                // Click again to close the right panel.
                vm.primarySurface = active ? nil : surface
            }
        } label: {
            if active {
                label
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .designShadow(Design.Shadow.card)
            } else {
                label.glassCard(cornerRadius: 12, shadow: Design.Shadow.card)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .scaleEffect(active ? 1.04 : 1.0)
        .animation(Design.Motion.pop, value: active)
    }
}
