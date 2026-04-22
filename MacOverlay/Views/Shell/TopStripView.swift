import SwiftUI
import AppKit

/// Compact title bar above the primary surface: editable session title,
/// mode badge, model picker, prominent Start/Stop CTA, and session menu.
/// The collapse-to-pill control lives in the sidebar brand logo (top-left).
struct TopStripView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingTitle = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 10) {
            titleField
            modeBadge
            Spacer()
            tokenChip
            startStopButton
            modelPicker
            sessionMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Live token counter for the active session, shown only when the user
    /// has enabled the toggle in Preferences.
    @ViewBuilder
    private var tokenChip: some View {
        if vm.showTokenCounts {
            let s = vm.sessionStore.activeSession
            let total = s.totalTokens
            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.system(size: 9, weight: .semibold))
                Text(formatted(total))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
            .help("\(s.totalInputTokens) in · \(s.totalOutputTokens) out · \(total) total")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private func formatted(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }

    // MARK: - Title

    @ViewBuilder
    private var titleField: some View {
        if editingTitle {
            TextField("Session title", text: $draftTitle, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: 260)
                .onExitCommand(perform: cancelEdit)
        } else {
            Button {
                draftTitle = vm.sessionStore.activeSession.displayTitle
                editingTitle = true
            } label: {
                Text(vm.sessionStore.activeSession.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .help("Click to rename")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Mode badge

    private var modeBadge: some View {
        Menu {
            Section("Built-in modes") {
                ForEach(SessionMode.allCases, id: \.self) { mode in
                    Button {
                        vm.sessionMode = mode
                        // If a conversation preset is linked to this mode,
                        // activate it automatically. Otherwise clear the
                        // active preset so the mode's built-in prompt runs.
                        if let linked = vm.promptStore.linkedPreset(for: mode) {
                            vm.promptStore.activePresetID = linked.id
                        } else {
                            vm.promptStore.activePresetID = nil
                        }
                    } label: {
                        HStack {
                            Label(mode.displayName, systemImage: mode.icon)
                            if vm.sessionMode == mode {
                                if let linked = vm.promptStore.linkedPreset(for: mode) {
                                    Text("(\(linked.name))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            let customModes = vm.promptStore.conversationPresets.filter { $0.linkedMode == nil }
            if !customModes.isEmpty {
                Section("Custom modes") {
                    ForEach(customModes) { preset in
                        Button {
                            vm.promptStore.activePresetID = preset.id
                        } label: {
                            HStack {
                                Label(preset.name, systemImage: preset.icon)
                                if vm.promptStore.activePresetID == preset.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                vm.primarySurface = .prompts
            } label: {
                Label("Manage custom prompts…", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.modeColor(vm.sessionMode))
                    .frame(width: 6, height: 6)
                Text(activeModeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Self.modeColor(vm.sessionMode).opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change mode or pick a custom prompt")
    }

    private var activeModeLabel: String {
        vm.promptStore.activePreset?.name ?? vm.sessionMode.displayName
    }

    // MARK: - Start / Stop (prominent CTA)

    @ViewBuilder
    private var startStopButton: some View {
        let streaming = vm.isSendingToAI
        let recording = vm.isInterviewSession || vm.isRecording
        let active = streaming || recording
        Button { primaryAction() } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "stop.fill" : "circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .symbolEffect(.pulse, options: active ? .repeating : .nonRepeating, value: active)
                Text(buttonLabel)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(active ? Color.red : buttonAccent)
            .clipShape(Capsule())
            .shadow(color: (active ? Color.red : buttonAccent).opacity(0.25), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(streaming ? "Stop generating" : (recording ? "Stop recording" : "Start (\(vm.sessionMode.displayName))"))
    }

    private var buttonLabel: String {
        if vm.isSendingToAI { return "Stop" }
        if vm.isInterviewSession { return "Stop" }
        if vm.isRecording { return "Stop" }
        switch vm.sessionMode {
        case .interview: return "Start Interview"
        case .meeting:   return "Start Meeting"
        case .call:      return "Start Call"
        case .general:   return "Record"
        }
    }

    private var buttonAccent: Color {
        switch vm.sessionMode {
        case .interview: return .green
        case .meeting:   return .blue
        case .call:      return .orange
        case .general:   return .accentColor
        }
    }

    private func primaryAction() {
        // Priority: stop streaming > stop recording > start recording.
        if vm.isSendingToAI {
            vm.cancelStreaming()
            return
        }
        if vm.sessionMode == .interview {
            if vm.isInterviewSession { vm.stopInterviewSession() }
            else                     { vm.startInterviewSession() }
        } else {
            vm.toggleRecording()
        }
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        Menu {
            Section("Anthropic") {
                ForEach(OverlayViewModel.availableModels.filter { $0.provider == "Anthropic" }, id: \.id) { m in
                    Button(m.name) { vm.selectedModel = m.id }
                }
            }
            Section("OpenAI") {
                ForEach(OverlayViewModel.availableModels.filter { $0.provider == "OpenAI" }, id: \.id) { m in
                    Button(m.name) { vm.selectedModel = m.id }
                }
            }
        } label: {
            Text(OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Session overflow

    private var sessionMenu: some View {
        Menu {
            Button { vm.startNewSession() } label: {
                Label("New Session", systemImage: "plus")
            }.keyboardShortcut("n", modifiers: .command)

            Button {
                draftTitle = vm.sessionStore.activeSession.displayTitle
                editingTitle = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Divider()

            Menu {
                Button("Copy as Markdown") { vm.copyActiveSessionAsMarkdown() }
                Button("Save as Markdown…") { vm.exportActiveSessionToDisk() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Menu {
                ForEach(AudioSource.allCases, id: \.self) { src in
                    Button {
                        vm.audioSource = src
                    } label: {
                        HStack {
                            Text(src.label)
                            if vm.audioSource == src { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Audio source: \(vm.audioSource.label)", systemImage: "waveform")
            }

            Divider()

            Button(role: .destructive) {
                vm.sessionStore.delete(id: vm.sessionStore.activeSessionID)
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            vm.sessionStore.rename(id: vm.sessionStore.activeSessionID, to: trimmed)
        }
        editingTitle = false
    }

    private func cancelEdit() {
        editingTitle = false
        draftTitle = ""
    }

    private static func modeColor(_ mode: SessionMode) -> Color {
        switch mode {
        case .general:   return .purple
        case .interview: return .green
        case .meeting:   return .blue
        case .call:      return .orange
        }
    }
}
