import SwiftUI

/// Tabbed preferences window body. Replaces the cramped gear popover.
struct PreferencesView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general   = "General"
        case profile   = "Profile"
        case ai        = "AI"
        case memory    = "Memory"
        case peer      = "Peer"
        case shortcuts = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:   return "slider.horizontal.3"
            case .profile:   return "person.crop.circle"
            case .ai:        return "sparkles"
            case .memory:    return "brain"
            case .peer:      return "person.2"
            case .shortcuts: return "keyboard"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases) { t in
                    tabRow(t)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 150)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Content
            ScrollView {
                Group {
                    switch tab {
                    case .general:   generalTab
                    case .profile:   profileTab
                    case .ai:        aiTab
                    case .memory:    memoryTab
                    case .peer:      peerTab
                    case .shortcuts: shortcutsTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 580, height: 460)
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
                    PreferencesWindowController.shared.close()
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
