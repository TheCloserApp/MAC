import SwiftUI

/// Replaces 6 icon buttons in the top bar with a single "Tools" popover that
/// opens a 2×3 grid. Labels + icons make the features discoverable instead of
/// relying on icon-memory.
struct ToolsMenuView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var isShown: Bool

    private var primaryTools: [Tool] {
        [
            Tool(icon: "calendar",         title: "Calendar",
                 active: vm.showCalendarPanel)    { vm.showCalendarPanel.toggle() },
            Tool(icon: "globe",            title: "Browser",
                 active: vm.hasBrowser)           { vm.toggleBrowser() },
            Tool(icon: "note.text",        title: "Notes",
                 active: vm.showNotesPanel)       { vm.showNotesPanel.toggle() },
            Tool(icon: "doc.badge.plus",   title: "Resume",
                 active: vm.showResumeBuilder)    { vm.showResumeBuilder.toggle() },
            Tool(icon: "keyboard",         title: "Type",
                 active: vm.showManualInput)      { vm.showManualInput.toggle() },
            Tool(icon: "camera.fill",      title: "Capture",
                 active: vm.pendingScreenshot != nil) {
                NotificationCenter.default.post(name: .captureScreenshot, object: nil)
            },
        ]
    }

    private var libraryTools: [Tool] {
        [
            Tool(icon: "clock.arrow.circlepath", title: "History",
                 active: vm.showHistoryPanel)     { vm.showHistoryPanel.toggle() },
            Tool(icon: "text.bubble",            title: "Prompts",
                 active: vm.showPromptLibraryPanel) { vm.showPromptLibraryPanel.toggle() },
            Tool(icon: "plus.bubble",            title: "New session",
                 active: false)                   { vm.startNewSession() },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Tools", tools: primaryTools)
            Divider()
            section("Library", tools: libraryTools)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func section(_ title: String, tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(tools) { t in
                    toolTile(t)
                }
            }
        }
    }

    private func toolTile(_ t: Tool) -> some View {
        Button {
            t.action()
            isShown = false
        } label: {
            VStack(spacing: 5) {
                Image(systemName: t.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(t.active ? .white : .primary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(t.active ? Color.accentColor : Color.primary.opacity(0.06))
                    )
                Text(t.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(t.active ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Tool: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let active: Bool
    let action: () -> Void
}
