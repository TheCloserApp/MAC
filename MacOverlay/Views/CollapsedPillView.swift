import SwiftUI

/// Collapsed pill — small horizontal capsule that expands on hover into a
/// macOS Dock-style strip of surface icons. Click an icon to open that
/// surface in the full chat panel. Click the brand to open with the last
/// surface (or chat by default).
struct CollapsedPillView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var hovering = false

    private var quickSurfaces: [OverlayViewModel.PrimarySurface] {
        let enabled = vm.workspaceStore.activeWorkspace.enabledFeatures
        let toggleable: [OverlayViewModel.PrimarySurface] =
            [.sessions, .prompts, .resumes, .calendar, .browser]
        return [.chat] + toggleable.filter { enabled.contains($0.rawValue) }
    }

    var body: some View {
        HStack(spacing: 2) {
            brandButton

            if hovering {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 0.5, height: 18)
                    .padding(.horizontal, 4)
                    .transition(.opacity)

                ForEach(Array(quickSurfaces.enumerated()), id: \.element) { _, surface in
                    surfaceButton(surface)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                Spacer(minLength: 2)

                settingsButton
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, hovering ? 6 : 0)
        .padding(.vertical, 0)
        .frame(height: 44)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 22/255, green: 22/255, blue: 24/255))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    stateAccent == .clear ? Color.white.opacity(0.10) : stateAccent,
                    lineWidth: stateAccent == .clear ? 0.75 : 1.5
                )
        )
        .designShadow(Design.Shadow.raised)
        .onHover { isHovering in
            withAnimation(Design.Motion.standard) {
                hovering = isHovering
            }
        }
        .help(hovering ? "" : "Hover to choose a surface")
    }

    // MARK: - Brand (waveform)

    private var brandButton: some View {
        Button {
            if vm.isQuickAsking {
                vm.toggleQuickAsk()
            } else {
                if vm.primarySurface == nil { vm.primarySurface = .chat }
                vm.isShellMinimized = false
                withAnimation(Design.Motion.spring) {
                    vm.isShellExpanded = true
                }
            }
        } label: {
            WaveformLogo()
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Surface buttons

    private func surfaceButton(_ surface: OverlayViewModel.PrimarySurface) -> some View {
        Button {
            vm.primarySurface = surface
            vm.isShellMinimized = false
            withAnimation(Design.Motion.spring) {
                vm.isShellExpanded = true
            }
        } label: {
            CapsuleHoverIcon(icon: surface.icon, tint: tintColor(for: surface))
        }
        .buttonStyle(.plain)
        .help(surface.displayName)
    }

    private var settingsButton: some View {
        Button {
            vm.primarySurface = .settings
            vm.isShellMinimized = false
            withAnimation(Design.Motion.spring) {
                vm.isShellExpanded = true
            }
        } label: {
            CapsuleHoverIcon(
                icon: "gearshape",
                tint: .secondary,
                attention: vm.needsKeyForCurrentModel
            )
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private func tintColor(for surface: OverlayViewModel.PrimarySurface) -> Color {
        switch surface {
        case .chat:     return Design.Accent.blue
        case .sessions: return Design.Accent.purple
        case .prompts:  return Design.Accent.pink
        case .resumes:  return Design.Accent.blue
        case .calendar: return Design.Accent.red
        case .browser:  return Design.Accent.teal
        case .settings: return .secondary
        }
    }

    private var stateAccent: Color {
        if vm.isDictating    { return Design.Accent.amber.opacity(0.70) }
        if vm.isQuickAsking  { return Design.Accent.red.opacity(0.60) }
        if vm.isRecording    { return Design.Accent.red.opacity(0.55) }
        return .clear
    }
}

private struct CapsuleHoverIcon: View {
    let icon: String
    let tint: Color
    var attention: Bool = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(attention ? Design.Accent.amber
                             : (hovering ? tint : .secondary.opacity(0.85)))
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(hovering ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Design.Motion.fast, value: hovering)
    }
}
