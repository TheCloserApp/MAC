import SwiftUI
import AppKit

struct SettingsPopoverView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                peerSection
                Divider()
                profileSection
                Divider()
                recordingSection
                Divider()
                promptSection
                Divider()
                appearanceSection
                Divider()
                apiKeysSection
                Divider()
                shortcutsSection
            }
            .padding(14)
        }
        .hiddenScrollGutter()
        .frame(minWidth: 280, maxHeight: 500)
    }

    @ViewBuilder
    private var peerSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            Text("Peer Control").font(.caption.weight(.semibold)).foregroundColor(.secondary)

            Toggle(isOn: $vm.peerControlEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow peer access").font(.caption)
                    Text("Lets a trusted colleague view your overlay and send messages to the AI")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if vm.peerServer.isRunning {
                peerStatusRow
            }
        }
    }

    private var peerStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.peerServer.connectedPeers > 0 ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(vm.peerServer.connectedPeers > 0
                     ? "\(vm.peerServer.connectedPeers) peer\(vm.peerServer.connectedPeers == 1 ? "" : "s") connected"
                     : "No peers connected — share the link below")
                    .font(.caption2)
                    .foregroundColor(vm.peerServer.connectedPeers > 0 ? .green : .secondary)
            }

            HStack(spacing: 6) {
                Text(vm.peerServer.connectionURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.peerServer.connectionURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy link")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Access code: \(vm.peerServer.accessCode)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            Text("Profile").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            profileField("Name", placeholder: "Your name",  text: $vm.userProfile.name)
            profileField("Role", placeholder: "Your role",  text: $vm.userProfile.currentRole)
            profileField("Company", placeholder: "Company", text: $vm.userProfile.company)
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            Toggle(isOn: $vm.vadEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-send on silence").font(.caption)
                    Text("Sends after ~2s of silence while recording")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        @Bindable var vm = vm
        let store = vm.promptStore
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Active Prompt").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Button("Manage…") { vm.showPromptLibraryPanel = true }
                    .font(.caption2).foregroundColor(.accentColor)
                    .buttonStyle(.plain)
            }

            if store.presets.isEmpty {
                Text("No saved prompts — \(vm.sessionMode.displayName) default is in use.")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
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
            }

            Divider().padding(.vertical, 2)

            memoryWithinSessionControls
            memoryAcrossSessionsControls
        }
    }

    @ViewBuilder
    private var memoryWithinSessionControls: some View {
        let store = vm.sessionStore
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { store.memorySyncEnabled },
                set: { store.memorySyncEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory within session").font(.caption)
                    Text("Replay previous turns from this session on every send.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if store.memorySyncEnabled {
                HStack(spacing: 8) {
                    Text("Context size")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Toggle(isOn: Binding(
                        get: { store.memoryIncludeAll },
                        set: { store.memoryIncludeAll = $0 }
                    )) {
                        Text("All").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    if !store.memoryIncludeAll {
                        Stepper(value: Binding(
                            get: { store.memoryWindow },
                            set: { store.memoryWindow = max(1, min(100, $0)) }
                        ), in: 1...100) {
                            Text("\(store.memoryWindow) turn\(store.memoryWindow == 1 ? "" : "s")")
                                .font(.caption.monospacedDigit())
                                .frame(width: 60, alignment: .leading)
                        }
                        .controlSize(.mini)
                    } else {
                        Text("Every turn in this session")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                .padding(.leading, 36)
            }
        }
    }

    @ViewBuilder
    private var memoryAcrossSessionsControls: some View {
        let store = vm.sessionStore
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { store.crossSessionMemoryEnabled },
                set: { store.crossSessionMemoryEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory across sessions").font(.caption)
                    Text("Also include one recent turn from past sessions.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!store.memorySyncEnabled)

            if store.memorySyncEnabled && store.crossSessionMemoryEnabled {
                HStack(spacing: 8) {
                    Text("Sessions to pull")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Stepper(value: Binding(
                        get: { store.crossSessionWindow },
                        set: { store.crossSessionWindow = max(1, min(20, $0)) }
                    ), in: 1...20) {
                        Text("\(store.crossSessionWindow)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .leading)
                    }
                    .controlSize(.mini)
                }
                .padding(.leading, 36)
            }
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            Text("Appearance").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            sliderRow(icon: "sun.max", label: "Opacity",
                      value: $vm.opacity, range: 0.2...1.0)
            sliderRow(icon: "square.dashed", label: "Background",
                      value: $vm.backgroundOpacity, range: 0.0...1.0,
                      display: { v in v == 0 ? "Off" : "\(Int(v * 100))%" })
        }
    }

    @ViewBuilder
    private var apiKeysSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            Text("API Keys").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            KeyFieldView(label: "Anthropic", placeholder: "sk-ant-api…", text: $vm.apiKey)
            KeyFieldView(label: "OpenAI",    placeholder: "sk-…",        text: $vm.openAIApiKey)
            KeyFieldView(label: "ElevenLabs", placeholder: "sk_…",       text: $vm.elevenLabsAPIKey)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Shortcuts").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            shortcutRow("Ctrl+Opt+↑↓←→",   "Move")
            shortcutRow("Ctrl+Shift+↑↓←→", "Resize")
            shortcutRow("Ctrl+Opt+T",       "Toggle record + send")
            shortcutRow("Ctrl+Opt+Y",       "Toggle record + send")
            shortcutRow("Ctrl+Opt+S",       "Screenshot → AI")
            shortcutRow("Ctrl+Opt+A",       "Send selected text to AI")
            shortcutRow("Ctrl+Opt+C",       "Explain clipboard")
            shortcutRow("Ctrl+Opt+Space",   "Toggle overlay")

            Divider().padding(.vertical, 4)

            Button("Replay welcome tour") { vm.showOnboarding = true }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
        }
    }

    private func profileField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption).foregroundColor(.secondary)
                .frame(width: 55, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    private func sliderRow(icon: String, label: String, value: Binding<Double>,
                           range: ClosedRange<Double>,
                           display: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundColor(.secondary).frame(width: 16)
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text(display?(value.wrappedValue) ?? "\(Int(value.wrappedValue * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.system(size: 10, design: .monospaced))
            Spacer()
            Text(desc).font(.caption2).foregroundColor(.secondary)
        }
    }
}
