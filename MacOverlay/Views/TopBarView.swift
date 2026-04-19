import SwiftUI

struct TopBarView: View {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var expanded: Bool
    @Binding var showModePicker: Bool
    @Binding var showSettingsPopover: Bool
    @State private var showToolsPopover = false

    private var activeToolCount: Int {
        [vm.showCalendarPanel, vm.hasBrowser, vm.showNotesPanel,
         vm.showResumeBuilder, vm.showManualInput, vm.pendingScreenshot != nil,
         vm.showHistoryPanel, vm.showPromptLibraryPanel]
            .filter { $0 }.count
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            collapseButton
            Divider().frame(height: 16).opacity(0.4)
            leftCluster
            Spacer()
            rightCluster
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { expanded = false }
            showModePicker = false
        } label: {
            WaveformLogo().padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var leftCluster: some View {
        HStack(spacing: 6) {
            if vm.isRecording || vm.isInterviewSession {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(vm.isInterviewSession ? Color.green : Color.red)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Color.clear.frame(width: 8, height: 8)
            }

            sourceTabs

            if vm.sessionMode == .interview {
                interviewButton
            } else {
                recordButton
            }
        }
    }

    private var sourceTabs: some View {
        HStack(spacing: 0) {
            ForEach(AudioSource.allCases, id: \.self) { src in
                let sel = vm.audioSource == src
                Text(src.label)
                    .font(.system(size: 11, weight: sel ? .semibold : .regular))
                    .foregroundColor(sel ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(sel ? Color(.selectedContentBackgroundColor).opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if !vm.isRecording { vm.audioSource = src } }
            }
        }
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .opacity(vm.isRecording ? 0.5 : 1)
    }

    private var interviewButton: some View {
        Button(action: {
            if vm.isInterviewSession { vm.stopInterviewSession() }
            else { vm.startInterviewSession() }
        }) {
            Text(vm.isInterviewSession ? "Stop" : "Start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(vm.isInterviewSession ? Color.red : Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button(action: { vm.toggleRecording() }) {
            Text(vm.isRecording ? "Stop" : "Record")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(vm.isRecording ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(vm.isRecording ? Color.red : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var rightCluster: some View {
        HStack(spacing: 10) {
            modeMenu
            Divider().frame(height: 14)
            modelMenu
            Divider().frame(height: 16).opacity(0.4)

            toolsButton

            peerIndicator
            sendButton
            settingsButton
        }
    }

    private var toolsButton: some View {
        Button { showToolsPopover.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(activeToolCount > 0 ? .accentColor : .primary.opacity(0.55))
                if activeToolCount > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -3)
                }
            }
            .frame(width: 22, height: 16)
        }
        .buttonStyle(.plain)
        .help(activeToolCount > 0 ? "Tools (\(activeToolCount) active)" : "Tools")
        .popover(isPresented: $showToolsPopover, arrowEdge: .bottom) {
            ToolsMenuView(isShown: $showToolsPopover)
                .environment(vm)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(SessionMode.allCases, id: \.self) { mode in
                Button {
                    vm.sessionMode = mode
                } label: {
                    Label(mode.displayName, systemImage: mode.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vm.sessionMode.icon)
                    .font(.system(size: 11))
                Text(vm.sessionMode.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modelMenu: some View {
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
                .foregroundColor(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var peerIndicator: some View {
        if vm.peerServer.isRunning {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(vm.peerServer.connectedPeers > 0 ? .green : .secondary)
                if vm.peerServer.connectedPeers > 0 {
                    Text("\(vm.peerServer.connectedPeers)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.green)
                        .clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: 22)
            .help("Peer control: \(vm.peerServer.connectedPeers) connected")
        }
    }

    private var sendButton: some View {
        Button { vm.sendToAI() } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13))
                .foregroundColor(vm.canSend ? .primary : .primary.opacity(0.2))
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSend)
        .help("Send to AI")
    }

    private var settingsButton: some View {
        Button { showSettingsPopover.toggle() } label: {
            Image(systemName: "gear")
                .font(.system(size: 13))
                .foregroundColor(vm.needsKeyForCurrentModel ? .orange : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            SettingsPopoverView()
        }
    }

    private func barIcon(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(active ? .primary : .primary.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}
