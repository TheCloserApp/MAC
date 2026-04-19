import SwiftUI
import AppKit

/// Compact dropdown showing the active workspace with a menu of all workspaces
/// plus "New workspace…" and "Manage…" actions. Lives above the primary
/// surface icons in the sidebar.
struct WorkspaceSwitcherView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showingNewSheet = false
    @State private var draftName = ""

    var body: some View {
        let active = vm.workspaceStore.activeWorkspace
        Menu {
            ForEach(vm.workspaceStore.workspaces) { w in
                Button {
                    vm.switchWorkspace(to: w.id)
                } label: {
                    HStack {
                        Image(systemName: w.icon)
                        Text(w.name)
                        if w.id == vm.workspaceStore.activeWorkspaceID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button {
                showingNewSheet = true
            } label: {
                Label("New workspace…", systemImage: "plus.square")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(color(for: active).opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: active.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color(for: active))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(active.name) · click to switch workspace")
        .popover(isPresented: $showingNewSheet, arrowEdge: .trailing) {
            NewWorkspaceSheet(isPresented: $showingNewSheet)
                .environment(vm)
        }
    }

    private func color(for w: Workspace) -> Color {
        Color(nsColor: NSColor(hex: w.colorHex) ?? NSColor.systemPurple)
    }
}

private struct NewWorkspaceSheet: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var icon = "tray"
    @State private var color = "#8E55FF"

    private let iconChoices = ["tray", "briefcase", "person", "sparkles", "bolt",
                                "globe", "graduationcap", "book", "star"]
    private let colorChoices = ["#8E55FF", "#FF5C8A", "#FFB020", "#34C759",
                                 "#5AC8FA", "#FF9500", "#AF52DE", "#00C7BE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New workspace").font(Design.Font.title)

            TextField("Name (e.g. Work, Interviews)", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Icon").font(Design.Font.eyebrow).foregroundColor(.secondary)
            HStack(spacing: 6) {
                ForEach(iconChoices, id: \.self) { opt in
                    Button { icon = opt } label: {
                        Image(systemName: opt)
                            .font(.system(size: 13))
                            .foregroundColor(icon == opt ? .white : .primary)
                            .frame(width: 26, height: 26)
                            .background(icon == opt ? Color.accentColor : Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Color").font(Design.Font.eyebrow).foregroundColor(.secondary)
            HStack(spacing: 6) {
                ForEach(colorChoices, id: \.self) { hex in
                    Button { color = hex } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .systemPurple))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(color == hex ? Color.primary : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                Button("Create") {
                    vm.addWorkspace(name: name, icon: icon, colorHex: color)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - Hex → NSColor

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1.0
        )
    }
}
