import SwiftUI

/// Named custom prompts. Select one to use. Add/edit/delete. The active prompt
/// overrides the session mode's default system prompt.
struct PromptLibraryView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingID: UUID? = nil
    @State private var draftName = ""
    @State private var draftContent = ""

    private var store: PromptStore { vm.promptStore }

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.presets.isEmpty && editingID == nil {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.presets) { p in
                            row(p)
                        }
                        if let id = editingID {
                            editor(id: id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(store.presets.count) saved prompt\(store.presets.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                beginEdit(.new)
            } label: {
                Label("New", systemImage: "plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
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
            Button("Create your first prompt") { beginEdit(.new) }
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

            ZStack(alignment: .topLeading) {
                if draftContent.isEmpty {
                    Text("You are an expert… Respond concisely. Use bullet points. Etc.")
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

    // MARK: - Edit state machine

    private enum EditTarget {
        case new
        case existing(PromptPreset)
    }

    private func beginEdit(_ target: EditTarget) {
        switch target {
        case .new:
            let placeholder = PromptPreset(name: "", content: "")
            store.presets.append(placeholder)
            editingID = placeholder.id
            draftName = ""
            draftContent = ""
        case .existing(let p):
            editingID = p.id
            draftName = p.name
            draftContent = p.content
        }
    }

    private func cancelEdit() {
        // If editing a brand-new empty placeholder, remove it
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
        p.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.content = draftContent
        store.update(p)
        if store.activePresetID == nil { store.activePresetID = p.id }
        editingID = nil
        draftName = ""
        draftContent = ""
    }
}
