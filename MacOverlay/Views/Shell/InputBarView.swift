import SwiftUI
import AppKit

/// ChatGPT-desktop-style composer. Layout:
///   ┌──────────────────────────────────────────────────┐
///   │ [multi-line text area]                           │
///   │                                                  │
///   │ [+]  [mode ▼]              [model ▼]  [🎤]  [↑]  │
///   └──────────────────────────────────────────────────┘
/// Plus button captures a screenshot, mode menu picks the session mode /
/// custom prompt, model menu picks the LLM, mic toggles recording (or
/// stops streaming), send fires the message.
struct InputBarView: View {
    @Environment(OverlayViewModel.self) private var vm
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 8) {
            if vm.pendingScreenshot != nil {
                screenshotChip
            }

            TextField("Ask anything", text: $vm.manualInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { send() }
                .padding(.top, 2)

            HStack(spacing: 3) {
                newSessionButton
                permissionsMenu
                surfaceButtons
                workspaceButton
                Spacer(minLength: 8)
                modelMenu
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                inputFocused = true
            }
        }
    }

    // MARK: - Left utilities

    private var newSessionButton: some View {
        Button {
            vm.startNewSession()
        } label: {
            iconCircle(systemName: "plus", tint: .secondary, weight: .semibold)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help("New session (⌘N)")
    }

    @ViewBuilder
    private var surfaceButtons: some View {
        let enabled = vm.workspaceStore.activeWorkspace.enabledFeatures
        surfaceButton(.sessions, icon: "clock.arrow.circlepath", label: "Sessions")
        surfaceButton(.prompts,  icon: "text.bubble",            label: "Prompts")
        surfaceButton(.resumes,  icon: "doc.richtext",           label: "Resumes")
        if enabled.contains("calendar") {
            surfaceButton(.calendar, icon: "calendar", label: "Calendar")
        }
        if enabled.contains("browser") {
            surfaceButton(.browser, icon: "globe", label: "Browser")
        }
        surfaceButton(.settings, icon: "gearshape", label: "Settings",
                      attention: vm.needsKeyForCurrentModel)
    }

    private func surfaceButton(_ surface: OverlayViewModel.PrimarySurface,
                               icon: String,
                               label: String,
                               attention: Bool = false) -> some View {
        let active = vm.primarySurface == surface
        return Button {
            withAnimation(Design.Motion.fast) {
                vm.primarySurface = active ? .chat : surface
            }
        } label: {
            iconCircle(
                systemName: icon,
                tint: attention ? Design.Accent.amber
                      : (active ? Design.Accent.blue : .secondary),
                size: 12,
                fill: active ? Design.Accent.blue.opacity(0.16) : Color.white.opacity(0.04)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var workspaceButton: some View {
        WorkspaceSwitcherView()
            .frame(width: 30, height: 30)
    }

    private var permissionsMenu: some View {
        PopUpChip(
            items: { modeMenuItems() },
            label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Design.modeColor(vm.sessionMode))
                        .frame(width: 6, height: 6)
                    Text(activeModeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(Capsule())
            }
        )
        .help("Mode and prompts")
    }

    private func modeMenuItems() -> [PopUpItem] {
        var items: [PopUpItem] = []
        items.append(.section("Built-in modes"))
        for mode in SessionMode.allCases {
            items.append(.option(
                mode.displayName,
                isSelected: vm.sessionMode == mode && vm.promptStore.activePreset == nil
            ) {
                vm.sessionMode = mode
                if let linked = vm.promptStore.linkedPreset(for: mode) {
                    vm.promptStore.activePresetID = linked.id
                } else {
                    vm.promptStore.activePresetID = nil
                }
            })
        }
        let customModes = vm.promptStore.conversationPresets.filter { $0.linkedMode == nil }
        if !customModes.isEmpty {
            items.append(.section("Custom modes"))
            for preset in customModes {
                let id = preset.id
                items.append(.option(
                    preset.name,
                    isSelected: vm.promptStore.activePresetID == id
                ) {
                    vm.promptStore.activePresetID = id
                })
            }
        }
        items.append(.option("Manage custom prompts…") {
            vm.primarySurface = .prompts
        })
        return items
    }


    private var activeModeLabel: String {
        vm.promptStore.activePreset?.name ?? vm.sessionMode.displayName
    }

    // MARK: - Right utilities

    private var modelMenu: some View {
        PopUpChip(
            items: { modelMenuItems() },
            label: {
                HStack(spacing: 4) {
                    Text(currentModelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
        )
        .help("Choose model")
    }

    private func modelMenuItems() -> [PopUpItem] {
        var items: [PopUpItem] = []
        let providers = ["Anthropic", "OpenAI"]
        for provider in providers {
            let models = OverlayViewModel.availableModels.filter { $0.provider == provider }
            guard !models.isEmpty else { continue }
            items.append(.section(provider))
            for m in models {
                let id = m.id
                items.append(.option(m.name, isSelected: vm.selectedModel == id) {
                    vm.selectedModel = id
                })
            }
        }
        return items
    }

    private var currentModelName: String {
        OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model"
    }

    private var micButton: some View {
        let streaming = vm.isSendingToAI
        let recording = vm.isInterviewSession || vm.isRecording
        let active = streaming || recording
        let interview = vm.sessionMode == .interview
        let idleIcon = interview ? "play.fill" : "mic"
        let idleSize: CGFloat = interview ? 10 : 12

        return Button { primaryAction() } label: {
            ZStack {
                Circle().fill(active ? Design.Accent.red.opacity(0.20) : Color.white.opacity(0.04))
                Circle().strokeBorder(
                    active ? Design.Accent.red.opacity(0.45) : Color.white.opacity(0.10),
                    lineWidth: 0.5
                )
                Image(systemName: active ? "stop.fill" : idleIcon)
                    .font(.system(size: active ? 10 : idleSize, weight: .semibold))
                    .foregroundColor(active ? Design.Accent.red : .secondary)
                    .symbolEffect(.pulse, options: active ? .repeating : .nonRepeating, value: active)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(streaming
              ? "Stop generating"
              : (recording
                 ? "Stop \(interview ? "interview" : "recording")"
                 : (interview ? "Start interview" : "Start recording")))
    }

    private func primaryAction() {
        if vm.isSendingToAI { vm.cancelStreaming(); return }
        if vm.sessionMode == .interview {
            if vm.isInterviewSession { vm.stopInterviewSession() }
            else                     { vm.startInterviewSession() }
        } else {
            vm.toggleRecording()
        }
    }

    private var sendButton: some View {
        let enabled = vm.canSend || !vm.manualInput.isEmpty
        return Button { send() } label: {
            ZStack {
                Circle().fill(enabled ? Design.Accent.blue : Color.white.opacity(0.04))
                Circle().strokeBorder(
                    enabled ? Color.white.opacity(0.22) : Color.white.opacity(0.10),
                    lineWidth: 0.5
                )
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(enabled ? .white : .secondary.opacity(0.5))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send (⏎)")
    }

    // MARK: - Helpers

    private func iconCircle(systemName: String,
                            tint: Color,
                            weight: Font.Weight = .regular,
                            size: CGFloat = 12,
                            fill: Color = Color.white.opacity(0.04)) -> some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(tint)
        }
        .frame(width: 30, height: 30)
    }

    // MARK: - Screenshot chip

    @ViewBuilder
    private var screenshotChip: some View {
        if let img = vm.pendingScreenshot {
            HStack(spacing: 8) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("Screenshot attached")
                    .font(Design.Font.tiny)
                    .foregroundColor(.secondary)
                Spacer()
                Button { vm.pendingScreenshot = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Design.Accent.blue.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.Accent.blue.opacity(0.20), lineWidth: 0.5)
            )
        }
    }

    private func send() {
        if !vm.manualInput.isEmpty { vm.showManualInput = true }
        vm.sendToAI()
    }
}
