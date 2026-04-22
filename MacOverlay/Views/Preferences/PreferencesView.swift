import SwiftUI

/// Tabbed preferences window body. Replaces the cramped gear popover.
struct PreferencesView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var tab: Tab = .general
    @State private var showNewWorkspaceSheet = false

    enum Tab: String, CaseIterable, Identifiable {
        case general    = "General"
        case profile    = "Profile"
        case ai         = "AI"
        case memory     = "Memory"
        case workspaces = "Workspaces"
        case peer       = "Peer"
        case shortcuts  = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:    return "slider.horizontal.3"
            case .profile:    return "person.crop.circle"
            case .ai:         return "sparkles"
            case .memory:     return "brain"
            case .workspaces: return "square.grid.2x2"
            case .peer:       return "person.2"
            case .shortcuts:  return "keyboard"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left tab rail
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases) { t in
                    tabRow(t)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 140)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Content
            ScrollView {
                Group {
                    switch tab {
                    case .general:    generalTab
                    case .profile:    profileTab
                    case .ai:         aiTab
                    case .memory:     memoryTab
                    case .workspaces: workspacesTab
                    case .peer:       peerTab
                    case .shortcuts:  shortcutsTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewWorkspaceSheet) {
            NewWorkspaceSheet(isPresented: $showNewWorkspaceSheet)
                .environment(vm)
        }
    }

    private func tabRow(_ t: Tab) -> some View {
        let active = tab == t
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { tab = t }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: t.icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(t.rawValue)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(active ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        @Bindable var vm = vm
        section(title: "Appearance") {
            sliderRow("Opacity", value: $vm.opacity, range: 0.2...1.0)
            sliderRow("Background", value: $vm.backgroundOpacity, range: 0.0...1.0,
                      display: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" })
        }

        section(title: "Recording") {
            Toggle(isOn: $vm.vadEnabled) {
                labelTwoLine(title: "Auto-send on silence",
                             subtitle: "Sends after ~2s of silence while recording.")
            }
            .toggleStyle(.switch)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                labelTwoLine(title: "Transcription engine",
                             subtitle: "Apple runs locally and is free. ElevenLabs is cloud-based and needs a key.")
                Spacer()
                Picker("", selection: $vm.transcriptionPreference) {
                    ForEach(OverlayViewModel.TranscriptionPreference.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
            }
        }

        section(title: "Onboarding") {
            Button("Replay welcome tour") { vm.showOnboarding = true }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var profileTab: some View {
        @Bindable var vm = vm
        section(title: "About you",
                subtitle: "Personalises interview and meeting responses. All optional.") {
            field("Name",    placeholder: "Alex",                text: $vm.userProfile.name)
            field("Role",    placeholder: "Software Engineer",   text: $vm.userProfile.currentRole)
            field("Company", placeholder: "Acme",                text: $vm.userProfile.company)
        }
    }

    @ViewBuilder
    private var aiTab: some View {
        @Bindable var vm = vm
        let store = vm.promptStore

        section(title: "API keys",
                subtitle: "Stored locally. Never uploaded.") {
            KeyFieldView(label: "Anthropic",  placeholder: "sk-ant-api…", text: $vm.apiKey)
            KeyFieldView(label: "OpenAI",     placeholder: "sk-…",        text: $vm.openAIApiKey)
            KeyFieldView(label: "ElevenLabs", placeholder: "sk_…",        text: $vm.elevenLabsAPIKey)
        }

        section(title: "Resume prompts",
                subtitle: "Pick a saved prompt, or drop in a one-off override. Save-as-preset to reuse across sessions.") {
            resumePromptPicker(
                kind: .resumeGeneration,
                label: "Generation prompt",
                overrideBinding: $vm.customResumeGenerationPrompt,
                activeIDBinding: Binding(
                    get: { store.activeResumeGenerationID },
                    set: { store.activeResumeGenerationID = $0 }
                ),
                defaultText: OverlayViewModel.defaultResumeGenerationPrompt
            )
            .padding(.bottom, 8)

            resumePromptPicker(
                kind: .resumeScoring,
                label: "Scoring prompt",
                overrideBinding: $vm.customResumeScoringPrompt,
                activeIDBinding: Binding(
                    get: { store.activeResumeScoringID },
                    set: { store.activeResumeScoringID = $0 }
                ),
                defaultText: OverlayViewModel.defaultResumeScoringPrompt
            )
        }

        section(title: "Usage") {
            Toggle(isOn: $vm.showTokenCounts) {
                labelTwoLine(title: "Show live token count",
                             subtitle: "Displays running token usage in the top strip. Updates as the AI streams.")
            }
            .toggleStyle(.switch)

            if vm.showTokenCounts {
                let s = vm.sessionStore.activeSession
                HStack(spacing: 14) {
                    tokenStat(label: "In",    value: s.totalInputTokens,  color: .blue)
                    tokenStat(label: "Out",   value: s.totalOutputTokens, color: .green)
                    tokenStat(label: "Total", value: s.totalTokens,       color: .accentColor)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }

        section(title: "Active prompt",
                subtitle: "Overrides the mode's default system prompt.") {
            HStack {
                Menu {
                    Button {
                        store.activePresetID = nil
                    } label: {
                        HStack {
                            Text("Use \(vm.sessionMode.displayName) default")
                            if store.activePresetID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(store.presets) { p in
                        Button {
                            store.activePresetID = p.id
                        } label: {
                            HStack {
                                Text(p.name)
                                if store.activePresetID == p.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(store.activePreset?.name ?? "\(vm.sessionMode.displayName) default")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)

                Button("Manage…") {
                    vm.primarySurface = .prompts
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var memoryTab: some View {
        let store = vm.sessionStore
        section(title: "Within session") {
            Toggle(isOn: Binding(get: { store.memorySyncEnabled },
                                 set: { store.memorySyncEnabled = $0 })) {
                labelTwoLine(title: "Replay previous turns",
                             subtitle: "Include prior user/assistant turns as context.")
            }
            .toggleStyle(.switch)

            if store.memorySyncEnabled {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { store.memoryIncludeAll },
                                         set: { store.memoryIncludeAll = $0 })) {
                        Text("All turns").font(.system(size: 12))
                    }
                    .toggleStyle(.switch)

                    if !store.memoryIncludeAll {
                        Stepper(value: Binding(get: { store.memoryWindow },
                                               set: { store.memoryWindow = $0 }),
                                in: 1...100) {
                            Text("\(store.memoryWindow) turn\(store.memoryWindow == 1 ? "" : "s")")
                                .font(.system(size: 12).monospacedDigit())
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }

        section(title: "Across sessions") {
            Toggle(isOn: Binding(get: { store.crossSessionMemoryEnabled },
                                 set: { store.crossSessionMemoryEnabled = $0 })) {
                labelTwoLine(title: "Pull from past sessions",
                             subtitle: "Include one recent turn from recent other sessions.")
            }
            .toggleStyle(.switch)
            .disabled(!store.memorySyncEnabled)

            if store.memorySyncEnabled && store.crossSessionMemoryEnabled {
                Stepper(value: Binding(get: { store.crossSessionWindow },
                                       set: { store.crossSessionWindow = $0 }),
                        in: 1...20) {
                    Text("Pull from \(store.crossSessionWindow) session\(store.crossSessionWindow == 1 ? "" : "s")")
                        .font(.system(size: 12).monospacedDigit())
                }
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private var workspacesTab: some View {
        @Bindable var vm = vm
        let store = vm.workspaceStore
        section(title: "Active workspace",
                subtitle: "Each workspace has its own sidebar of features.") {
            HStack {
                Spacer()
                Button {
                    showNewWorkspaceSheet = true
                } label: {
                    Label("New workspace", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.bottom, 4)

            VStack(spacing: 6) {
                ForEach(store.workspaces) { w in
                    WorkspaceRow(
                        workspace: w,
                        isActive: w.id == store.activeWorkspaceID,
                        onSelect: { vm.switchWorkspace(to: w.id) },
                        onRename: { newName in
                            var updated = w
                            updated.name = newName
                            store.update(updated)
                        },
                        onToggleFeature: { feature in
                            var updated = w
                            if updated.enabledFeatures.contains(feature) {
                                updated.enabledFeatures.remove(feature)
                            } else {
                                updated.enabledFeatures.insert(feature)
                            }
                            store.update(updated)
                        },
                        onDelete: w.isDefault ? nil : { vm.deleteWorkspace(id: w.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var peerTab: some View {
        @Bindable var vm = vm
        section(title: "Peer control",
                subtitle: "Let a colleague view your overlay and send messages to the AI.") {
            Toggle(isOn: $vm.peerControlEnabled) {
                Text("Allow peer access").font(.system(size: 12))
            }
            .toggleStyle(.switch)

            if vm.peerServer.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.peerServer.connectedPeers > 0 ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(vm.peerServer.connectedPeers > 0
                             ? "\(vm.peerServer.connectedPeers) peer\(vm.peerServer.connectedPeers == 1 ? "" : "s") connected"
                             : "No peers connected — share the link below")
                            .font(.caption)
                    }

                    HStack(spacing: 6) {
                        Text(vm.peerServer.connectionURL)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.peerServer.connectionURL, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("Access code: \(vm.peerServer.accessCode)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsTab: some View {
        section(title: "Global shortcuts") {
            VStack(spacing: 2) {
                shortcut("⌃⌥Space", "Show / hide overlay")
                shortcut("⌃⌥T",      "Toggle recording + send")
                shortcut("⌃⌥S",      "Capture screenshot → AI")
                shortcut("⌃⌥A",      "Send selected text to AI")
                shortcut("⌃⌥C",      "Explain clipboard")
                shortcut("⌃⌥R",      "Tailor resume from clipboard JD")
                shortcut("⌃⌥ ↑↓←→",  "Move overlay")
                shortcut("⌃⇧ ↑↓←→",  "Resize overlay")
                shortcut("⌘N",        "New session")
                shortcut("⌘,",        "Preferences")
            }
        }
    }

    // MARK: - Builders

    @ViewBuilder
    private func section<Content: View>(title: String, subtitle: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(.bottom, 16)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>,
                           display: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text(display?(value.wrappedValue) ?? "\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func tokenStat(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func labelTwoLine(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12))
            Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-kind resume-prompt picker row. Shows a menu of saved presets (for
    /// that kind), an inline override editor, and a "Save as preset" button
    /// so users can turn a tweaked override into a named library item.
    @ViewBuilder
    private func resumePromptPicker(
        kind: PromptPreset.Kind,
        label: String,
        overrideBinding: Binding<String>,
        activeIDBinding: Binding<UUID?>,
        defaultText: String
    ) -> some View {
        let store = vm.promptStore
        let kindPresets = kind == .resumeGeneration
            ? store.resumeGenerationPresets
            : store.resumeScoringPresets
        let activePreset = kind == .resumeGeneration
            ? store.activeResumeGenerationPreset
            : store.activeResumeScoringPreset

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !overrideBinding.wrappedValue.isEmpty {
                    Button("Reset override") { overrideBinding.wrappedValue = "" }
                        .font(.caption2).foregroundColor(.orange)
                        .buttonStyle(.plain)
                }
            }

            Menu {
                Button {
                    activeIDBinding.wrappedValue = nil
                } label: {
                    HStack {
                        Text("Default")
                        if activeIDBinding.wrappedValue == nil { Image(systemName: "checkmark") }
                    }
                }
                if !kindPresets.isEmpty {
                    Divider()
                    ForEach(kindPresets) { p in
                        Button {
                            activeIDBinding.wrappedValue = p.id
                        } label: {
                            HStack {
                                Text(p.name)
                                if activeIDBinding.wrappedValue == p.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    let trimmed = overrideBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = trimmed.isEmpty ? defaultText : trimmed
                    let preset = store.add(
                        name: kind == .resumeGeneration ? "New gen prompt" : "New score prompt",
                        content: content,
                        kind: kind,
                        icon: "doc.text"
                    )
                    activeIDBinding.wrappedValue = preset.id
                    overrideBinding.wrappedValue = ""
                } label: {
                    Label("Save override as preset", systemImage: "square.and.arrow.down")
                }
                .disabled(overrideBinding.wrappedValue.isEmpty)
                Button {
                    vm.primarySurface = .prompts
                } label: {
                    Label("Manage prompts library", systemImage: "text.bubble")
                }
            } label: {
                HStack {
                    Text(activePreset?.name ?? (overrideBinding.wrappedValue.isEmpty ? "Default" : "Custom override"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)

            // Inline override editor — applies when no preset is selected.
            TextEditor(text: overrideBinding)
                .font(.system(size: 11))
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .disabled(activePreset != nil)
                .opacity(activePreset == nil ? 1.0 : 0.45)

            Group {
                if let preset = activePreset {
                    Text("Using preset “\(preset.name)”")
                        .font(.caption2).foregroundColor(.accentColor)
                } else {
                    Text(overrideBinding.wrappedValue.isEmpty
                         ? "Default: \(defaultText)"
                         : "Using inline override.")
                        .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcut(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer()
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Workspace row (used in Workspaces tab)

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onToggleFeature: (String) -> Void
    let onDelete: (() -> Void)?

    @State private var isEditing = false
    @State private var draftName = ""

    private let allFeatures: [(key: String, label: String, icon: String)] = [
        ("sessions", "History",  "clock.arrow.circlepath"),
        ("prompts",  "Prompts",  "text.bubble"),
        ("resumes",  "Resumes",  "doc.text"),
        ("calendar", "Calendar", "calendar"),
        ("browser",  "Browser",  "globe"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: NSColor(hex: workspace.colorHex) ?? .systemPurple))
                    .frame(width: 10, height: 10)

                if isEditing {
                    TextField("Workspace name", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .semibold))
                        .onExitCommand { isEditing = false }
                } else {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .semibold))
                }

                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                if workspace.isDefault {
                    Text("DEFAULT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }

                Spacer()

                if !isActive {
                    Button("Switch") { onSelect() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                Button {
                    if isEditing { commitRename() }
                    else {
                        draftName = workspace.name
                        isEditing = true
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Feature toggles
            VStack(spacing: 2) {
                ForEach(allFeatures, id: \.key) { f in
                    let on = workspace.enabledFeatures.contains(f.key)
                    Button {
                        onToggleFeature(f.key)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: f.icon)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text(f.label)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(on ? .accentColor : .secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != workspace.name {
            onRename(trimmed)
        }
        isEditing = false
    }
}
