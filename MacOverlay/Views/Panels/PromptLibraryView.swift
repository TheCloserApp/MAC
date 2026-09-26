import SwiftUI

/// Named custom prompts. Select one to use. Add/edit/delete. The active prompt
/// overrides the session mode's default system prompt.
struct PromptLibraryView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingID: UUID? = nil
    @State private var draftName = ""
    @State private var draftContent = ""
    @State private var draftKind: PromptPreset.Kind = .conversation
    @State private var draftIcon: String = "text.bubble.fill"
    @State private var draftLinkedMode: SessionMode? = nil
    @State private var filter: Filter = .all

    enum Filter: Hashable {
        case all
        case kind(PromptPreset.Kind)
    }

    private var store: PromptStore { vm.promptStore }

    /// Résumé generation and scoring prompts belong to the résumé feature;
    /// while it's off, only conversation prompts are listed.
    private var visiblePresets: [PromptPreset] {
        FeatureFlags.resumesEnabled ? store.presets : store.presets.filter { $0.kind == .conversation }
    }

    private var filteredPresets: [PromptPreset] {
        switch filter {
        case .all: return visiblePresets
        case .kind(let k): return visiblePresets.filter { $0.kind == k }
        }
    }

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            if FeatureFlags.resumesEnabled { filterBar }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            if filteredPresets.isEmpty && editingID == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredPresets) { p in
                            row(p)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .hiddenScrollGutter()
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text("Prompts")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(.primary)
            Text("\(visiblePresets.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            Spacer()
            if FeatureFlags.resumesEnabled {
                Menu {
                    Button { beginEdit(.new(kind: .conversation)) } label: {
                        Label("New conversation prompt", systemImage: "bubble.left.and.bubble.right")
                    }
                    Button { beginEdit(.new(kind: .resumeGeneration)) } label: {
                        Label("New resume generation prompt", systemImage: "doc.text")
                    }
                    Button { beginEdit(.new(kind: .resumeScoring)) } label: {
                        Label("New resume scoring prompt", systemImage: "chart.bar")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button { beginEdit(.new(kind: .conversation)) } label: {
                    Label("New prompt", systemImage: "plus")
                }
                .buttonStyle(.primaryCompact)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            filterChip("All",     match: .all)
            filterChip("Chat",    match: .kind(.conversation))
            filterChip("Gen",     match: .kind(.resumeGeneration))
            filterChip("Scoring", match: .kind(.resumeScoring))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func filterChip(_ label: String, match: Filter) -> some View {
        let active = filter == match
        return Button {
            withAnimation(Design.Motion.fast) { filter = match }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .primary : .secondary.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? Color.white.opacity(0.10) : .clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        active ? Color.white.opacity(0.18) : Color.white.opacity(0.08),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        let createKind: PromptPreset.Kind
        switch filter {
        case .kind(let k): createKind = k
        case .all:         createKind = .conversation
        }
        return VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No saved prompts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Save reusable system prompts like \"FAANG Interview\" or \"Sales Call\".")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            Button("Create your first prompt") { beginEdit(.new(kind: createKind)) }
                .buttonStyle(.primaryCompact)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func row(_ p: PromptPreset) -> some View {
        let isActive = p.id == store.activePresetID
        let isEditing = p.id == editingID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isActive ? Color.accentColor : .clear)
                    .frame(width: 2.5)
                    .padding(.vertical, 4)

                Image(systemName: p.icon)
                    .font(.system(size: 11))
                    .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.name)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    Text(p.content)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    Button { beginEdit(.existing(p)) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        store.delete(id: p.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 4)

            if isEditing {
                editor(id: p.id)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous)
                .fill(isActive && !isEditing
                      ? Color.accentColor.opacity(0.08)
                      : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if editingID == nil { store.activePresetID = p.id }
        }
    }

    private func editor(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Prompt name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if draftKind == .conversation {
                HStack(spacing: 6) {
                    Text("Link to mode")
                        .font(.caption2).foregroundColor(.secondary)
                    Menu {
                        Button {
                            draftLinkedMode = nil
                        } label: {
                            HStack {
                                Text("None (custom mode)")
                                if draftLinkedMode == nil { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(SessionMode.allCases, id: \.self) { mode in
                            Button {
                                draftLinkedMode = mode
                            } label: {
                                HStack {
                                    Label(mode.displayName, systemImage: mode.icon)
                                    if draftLinkedMode == mode { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(draftLinkedMode?.displayName ?? "Custom (none)")
                                .font(.system(size: 11))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu {
                        ForEach(iconChoices, id: \.self) { icon in
                            Button { draftIcon = icon } label: {
                                HStack {
                                    Label(icon, systemImage: icon)
                                    if draftIcon == icon { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: draftIcon).font(.system(size: 11))
                            Text("Icon").font(.system(size: 11))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()
                }
            }

            ZStack(alignment: .topLeading) {
                if draftContent.isEmpty {
                    Text(placeholderText(for: draftKind))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.45))
                        .padding(8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draftContent)
                    .font(.system(size: 11))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
            }
            .padding(4)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Cancel") { cancelEdit() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                Spacer()

                Button("Save") { saveEdit() }
                    .buttonStyle(.primaryCompact)
                    .disabled(draftName.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private let iconChoices = [
        "text.bubble.fill", "bubble.left.and.bubble.right", "sparkles",
        "person.fill.checkmark", "phone.fill", "person.3.fill", "brain",
        "bolt.fill", "star.fill", "book", "graduationcap", "globe"
    ]

    private func placeholderText(for kind: PromptPreset.Kind) -> String {
        switch kind {
        case .conversation:
            return "You are an expert… Respond concisely. Use bullet points. Etc."
        case .resumeGeneration:
            return "You are an expert resume writer. Output plain text with ALL CAPS section headings…"
        case .resumeScoring:
            return "You are an ATS expert. Always respond in the exact format requested…"
        }
    }

    // MARK: - Edit state machine

    private enum EditTarget {
        case new(kind: PromptPreset.Kind)
        case existing(PromptPreset)
    }

    private func beginEdit(_ target: EditTarget) {
        switch target {
        case .new(let kind):
            let placeholder = PromptPreset(name: "", content: "", kind: kind)
            store.presets.append(placeholder)
            editingID = placeholder.id
            draftName = ""
            draftContent = ""
            draftKind = kind
            draftIcon = kind == .conversation ? "text.bubble.fill" : "doc.text"
            draftLinkedMode = nil
            // Scroll the kind filter to match, so the new row is visible.
            filter = .kind(kind)
        case .existing(let p):
            editingID = p.id
            draftName = p.name
            draftContent = p.content
            draftKind = p.kind
            draftIcon = p.icon
            draftLinkedMode = p.linkedMode
        }
    }

    private func cancelEdit() {
        if let id = editingID,
           let p = store.presets.first(where: { $0.id == id }),
           p.name.isEmpty, p.content.isEmpty {
            store.delete(id: id)
        }
        editingID = nil
        draftName = ""
        draftContent = ""
    }

    private func saveEdit() {
        guard let id = editingID else { return }
        guard var p = store.presets.first(where: { $0.id == id }) else { return }
        p.name       = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.content    = draftContent
        p.kind       = draftKind
        p.icon       = draftIcon
        p.linkedMode = draftLinkedMode
        store.update(p)
        // Auto-activate a freshly-created conversation preset only if nothing's active.
        if p.kind == .conversation && store.activePresetID == nil {
            store.activePresetID = p.id
        }
        editingID = nil
        draftName = ""
        draftContent = ""
    }
}
