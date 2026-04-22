import SwiftUI

/// Sidebar column. Cells are Control-Center-style tinted glass pills, grouped
/// into a primary (close / + / feature) block and a footer (workspace /
/// settings) block. When the shell expands, each cell cascades in with a
/// small staggered drop so the sidebar feels like it unfolds from the pill.
struct SidebarView: View {
    @Environment(OverlayViewModel.self) private var vm

    private let alwaysVisible: [OverlayViewModel.PrimarySurface] = [.chat]
    private let toggleable: [OverlayViewModel.PrimarySurface] = [
        .sessions, .prompts, .resumes, .calendar, .browser
    ]

    private var visibleFeatures: [OverlayViewModel.PrimarySurface] {
        let enabled = vm.workspaceStore.activeWorkspace.enabledFeatures
        return alwaysVisible + toggleable.filter { enabled.contains($0.rawValue) }
    }

    var body: some View {
        // Fixed top-to-bottom order regardless of where the pill sits on screen.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                headerGroup
                Spacer(minLength: 0)
                footerGroup
            }
            .padding(.vertical, 2)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 44)
    }

    // MARK: - Groups

    private var headerGroup: some View {
        VStack(spacing: 6) {
            cascaded(index: 0) { closeCell }
            cascaded(index: 1) { newSessionCell }
            ForEach(Array(visibleFeatures.enumerated()), id: \.element) { i, surface in
                cascaded(index: 2 + i) { surfaceCell(surface) }
            }
        }
    }

private var footerGroup: some View {
        VStack(spacing: 6) {
            cascaded(index: 99) { workspaceCell }
            cascaded(index: 100) { surfaceCell(.settings) }
        }
    }

    @ViewBuilder
    private func cascaded<V: View>(index: Int, @ViewBuilder _ content: () -> V) -> some View {
        content()
    }

    // MARK: - Cells

    private var closeCell: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                vm.isShellExpanded = false
            }
        } label: {
            TintedIconCell(
                icon: "xmark",
                weight: .semibold,
                tint: .primary.opacity(0.75),
                isActive: false
            )
        }
        .buttonStyle(.plain)
        .help("Collapse to pill")
    }

    private var newSessionCell: some View {
        Button { vm.startNewSession() } label: {
            TintedIconCell(
                icon: "plus",
                weight: .semibold,
                tint: .white,
                backgroundTint: .accentColor,
                isActive: true
            )
        }
        .buttonStyle(.plain)
        .help("New session (⌘N)")
    }

    private var workspaceCell: some View {
        WorkspaceSwitcherView()
            .frame(width: 34, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func surfaceCell(_ surface: OverlayViewModel.PrimarySurface) -> some View {
        let active = vm.primarySurface == surface
        Button {
            withAnimation(Design.Motion.pop) {
                vm.primarySurface = active ? nil : surface
            }
        } label: {
            TintedIconCell(
                icon: active ? surface.activeIcon : surface.icon,
                weight: active ? .semibold : .regular,
                tint: active ? tintColor(for: surface) : .primary.opacity(0.6),
                backgroundTint: active ? tintColor(for: surface).opacity(0.16) : nil,
                isActive: active,
                highlightTint: surface == .settings && vm.needsKeyForCurrentModel ? .orange : nil
            )
        }
        .buttonStyle(.plain)
        .help(surface.displayName)
    }

    /// Per-surface accent. Slightly desaturated so a column of pills doesn't
    /// look like a Christmas tree — similar to macOS system-setting icons.
    private func tintColor(for surface: OverlayViewModel.PrimarySurface) -> Color {
        switch surface {
        case .chat:     return .accentColor
        case .sessions: return Color(nsColor: .systemIndigo)
        case .prompts:  return Color(nsColor: .systemPink)
        case .resumes:  return Color(nsColor: .systemBlue)
        case .calendar: return Color(nsColor: .systemRed)
        case .browser:  return Color(nsColor: .systemTeal)
        case .settings: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Tinted cell

/// 34×34 glass pill with a tinted icon. Mirrors macOS Control-Center look:
/// subtle material base, very light border, color tint only on the icon when
/// inactive, soft tint fill on the icon's background when active.
private struct TintedIconCell: View {
    let icon: String
    var weight: Font.Weight = .regular
    let tint: Color
    /// When set, the cell's background fills with this tint (active state).
    var backgroundTint: Color? = nil
    var isActive: Bool = false
    /// Override color for attention states (e.g. missing API key).
    var highlightTint: Color? = nil

    @State private var hovering = false

    var body: some View {
        ZStack {
            // Soft material background so the cell reads as "glass chip".
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
            // Hover / active tint — kept light so pills stay cohesive.
            if let backgroundTint {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundTint)
                    .transition(.opacity)
            } else if hovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(isActive ? 0.08 : 0.05), lineWidth: 0.5)

            Image(systemName: icon)
                .font(.system(size: 13, weight: weight))
                .foregroundColor(highlightTint ?? tint)
        }
        .frame(width: 34, height: 34)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Design.Motion.pop, value: isActive)
    }
}
