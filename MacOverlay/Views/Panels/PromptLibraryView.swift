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

    private var filteredPresets: [PromptPreset] {
        switch filter {
        case .all: return store.presets
        case .kind(let k): return store.presets.filter { $0.kind == k }
        }
    }

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar

            Divider()

            if filteredPresets.isEmpty && editingID == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredPresets) { p in
                            row(p)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(store.presets.count) saved prompt\(store.presets.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Menu {
                Button {
                    beginEdit(.new(kind: .conversation))
                } label: {
                    Label("New conversation prompt", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    beginEdit(.new(kind: .resumeGeneration))
                } label: {
                    Label("New resume generation prompt", systemImage: "doc.text")
                }
                Button {
                    beginEdit(.new(kind: .resumeScoring))
                } label: {
                    Label("New resume scoring prompt", systemImage: "chart.bar")
                }
            } label: {
                Label("New", systemImage: "plus")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            filterChip("All",     match: .all)
            filterChip("Chat",    match: .kind(.conversation))
            filterChip("Gen",     match: .kind(.resumeGeneration))
            filterChip("Scoring", match: .kind(.resumeScoring))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func filterChip(_ label: String, match: Filter) -> some View {
        let active = filter == match
        return Button {
            withAnimation(Design.Motion.fast) { filter = match }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .white : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
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
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func row(_ p: PromptPreset) -> some View {
        let isActive = p.id == store.activePresetID
        let isEditing = p.id == editingID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : .clear)
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.name)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .lineLimit(1)
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    Text(p.content)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Button { beginEdit(.existing(p)) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        store.delete(id: p.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)

            if isEditing {
                editor(id: p.id)
            }
        }
        .background(isActive && !isEditing ? Color.accentColor.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(draftName.isEmpty ? Color.secondary : Color.accentColor)
                    .clipShape(Capsule())
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
