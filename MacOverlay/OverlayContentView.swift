import SwiftUI
import EventKit
import QuickLookUI

struct OverlayView: View {
    @EnvironmentObject var vm: OverlayViewModel
    @State private var showSettingsPopover = false
    @State private var dotVisible = true
    @State private var expanded = false
    @State private var showModePicker = false

    private var hasContent: Bool {
        vm.isRecording || vm.isInterviewSession || !vm.transcription.isEmpty
            || !vm.statusMessage.isEmpty
            || vm.showManualInput
            || vm.pendingScreenshot != nil
            || vm.isSendingToAI || !vm.aiResponse.isEmpty
            || vm.showNotesPanel
            || vm.showCalendarPanel
            || vm.hasBrowser
            || vm.showResumeBuilder
            || !vm.peerMessage.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                // ── Full bar pill ─────────────────────────────────────
                bar
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .opacity(vm.backgroundOpacity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                // ── Collapsed: click → mode picker ────────────────────
                Button {
                    if vm.isQuickAsking {
                        vm.toggleQuickAsk()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            showModePicker.toggle()
                        }
                    }
                } label: {
                    Group {
                        if showModePicker && !vm.isQuickAsking {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 26, height: 22)
                        } else {
                            WaveformLogo()
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                                .opacity(vm.backgroundOpacity)
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    vm.isDictating  ? Color.orange.opacity(0.6)
                                    : vm.isQuickAsking ? Color.red.opacity(0.5)
                                    : vm.isRecording   ? Color.red.opacity(0.4)
                                    : Color.primary.opacity(0.06),
                                    lineWidth: vm.isDictating || vm.isQuickAsking || vm.isRecording ? 1.5 : 1
                                )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(
                        color: vm.isDictating ? Color.orange.opacity(0.25)
                             : vm.isRecording  ? Color.red.opacity(0.2)
                             : Color.black.opacity(0.12),
                        radius: vm.isDictating || vm.isRecording ? 10 : 6,
                        x: 0, y: 2
                    )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: vm.isDictating)
                .animation(.easeInOut(duration: 0.2), value: vm.isRecording)

                // Mode picker pop-up
                if showModePicker {
                    modePicker
                        .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                }

                // Resume pill — visible in icon mode whenever score or file is ready
                if vm.resumeFileURL != nil || vm.isGeneratingResume
                   || vm.resumeScore != nil || vm.isScoringResume {
                    resumeFloatingPill
                }

                // Quick ask pill — visible when processing or response is ready
                // (listening state is shown by the animated waveform icon itself)
                if vm.isQuickAskSending || !vm.quickAskResponse.isEmpty {
                    quickAskFloatingPill
                }

                // Dictation: state is reflected via orange icon border only (no floating pill)
            }

            // ── Content panel ─────────────────────────────────────────
            if expanded && hasContent {
                VStack(spacing: 0) {
                    if !vm.statusMessage.isEmpty && !vm.isRecording && !vm.isInterviewSession && vm.transcription.isEmpty {
                        statusRow
                    }
                    if vm.isRecording || vm.isInterviewSession || !vm.transcription.isEmpty {
                        transcriptionRow
                        if hasMoreBelowTranscription { Divider() }
                    }
                    if vm.isRecording || vm.isInterviewSession || !vm.transcription.isEmpty {
                        quickActionBar
                    }
                    if !vm.peerMessage.isEmpty {
                        Divider()
                        peerMessageRow
                    }
                    if vm.showManualInput {
                        Divider()
                        manualInputRow
                    }
                    if vm.pendingScreenshot != nil {
                        Divider()
                        screenshotRow
                    }
                    if vm.isSendingToAI || !vm.aiResponse.isEmpty {
                        Divider()
                        responseArea
                    }
                    if vm.showCalendarPanel {
                        Divider()
                        calendarPanel
                    }
                    if vm.showNotesPanel {
                        Divider()
                        notesPanel
                    }
                    if vm.showResumeBuilder {
                        Divider()
                        resumePanel
                    }
                    if vm.hasBrowser {
                        Divider()
                        BrowserPanelView()
                            .environmentObject(vm)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: vm.hasBrowser ? .infinity : nil, alignment: .top)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .opacity(vm.backgroundOpacity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: vm.hasBrowser ? .infinity : nil, alignment: .topLeading)
        .padding(8)
        .onReceive(
            Timer.publish(every: 0.6, on: .main, in: .common)
                .autoconnect()
                .filter { _ in vm.isRecording || vm.isInterviewSession }
        ) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { dotVisible.toggle() }
        }
        .onChange(of: vm.isRecording) { if !$0 && !vm.isInterviewSession { dotVisible = true } }
        .onChange(of: vm.isInterviewSession) { if !$0 { dotVisible = true } }
    }

    private var hasMoreBelowTranscription: Bool {
        !vm.peerMessage.isEmpty || vm.showManualInput || vm.pendingScreenshot != nil
            || vm.isSendingToAI || !vm.aiResponse.isEmpty
            || vm.showCalendarPanel || vm.showNotesPanel || vm.hasBrowser || vm.showResumeBuilder
    }

    // MARK: - Bar

    private var bar: some View {
        HStack(alignment: .center, spacing: 10) {

            // Collapse button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { expanded = false }
                showModePicker = false
            } label: {
                WaveformLogo()
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16).opacity(0.4)

            // LEFT: dot + source + record
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isInterviewSession ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .opacity((vm.isRecording || vm.isInterviewSession) ? (dotVisible ? 1 : 0) : 0)

                // Source tabs
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

                if vm.sessionMode == .interview {
                    // Interview: continuous real-time session button
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
                } else {
                    // Other modes: one-shot record button
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
            }

            Spacer()

            // RIGHT: mode + model + icons
            HStack(spacing: 12) {
                // Mode picker
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

                Divider().frame(height: 14)

                // Model picker
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

                Divider().frame(height: 16).opacity(0.4)

                // Calendar
                barIcon("calendar", active: vm.showCalendarPanel) { vm.showCalendarPanel.toggle() }
                    .help("Calendar")

                // Browser
                barIcon("globe", active: vm.hasBrowser) { vm.toggleBrowser() }
                    .help("Browser")

                // Notes
                barIcon("note.text", active: vm.showNotesPanel) { vm.showNotesPanel.toggle() }
                    .help("Notes")

                // Resume
                barIcon("doc.badge.plus", active: vm.showResumeBuilder) { vm.showResumeBuilder.toggle() }
                    .help("Resume builder")

                // Keyboard input
                barIcon("keyboard", active: vm.showManualInput) { vm.showManualInput.toggle() }
                    .help("Type a message")

                // Screenshot
                barIcon("camera.fill", active: vm.pendingScreenshot != nil) {
                    NotificationCenter.default.post(name: .captureScreenshot, object: nil)
                }
                .help("Screenshot (Ctrl+Opt+S)")

                Divider().frame(height: 16).opacity(0.4)

                // Peer control indicator (shown when server is running)
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

                // Send
                Button { vm.sendToAI() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13))
                        .foregroundColor(vm.canSend ? .primary : .primary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
                .help("Send to AI")

                // Settings
                Button { showSettingsPopover.toggle() } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .foregroundColor(vm.needsKeyForCurrentModel ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    settingsPopover
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func barIcon(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(active ? .primary : .primary.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick action chips

    private var quickActionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.sessionMode.quickActions) { action in
                    Button {
                        vm.selectQuickAction(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Status / error row

    private var statusRow: some View {
        let isError = vm.statusMessage.hasPrefix("Error") || vm.statusMessage.hasPrefix("Screen Recording")
        return HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundColor(isError ? .orange : .secondary)
            Text(vm.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(isError ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { vm.statusMessage = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcription row

    private var transcriptionRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(vm.transcription.isEmpty ? "Listening…" : vm.transcription)
                    .font(.system(size: 12))
                    .foregroundStyle(vm.transcription.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(.easeInOut(duration: 0.15), value: vm.transcription)

                if !vm.transcription.isEmpty {
                    Button { vm.transcription = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, vm.transcription.isEmpty ? 10 : 6)

            // Character count hint when transcript is long
            if vm.transcription.count > 120 {
                Text("\(vm.transcription.count) chars")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Peer message (staged, awaiting local user approval)

    private var peerMessageRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.purple.opacity(0.8))
                Text("Peer wants to ask:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.purple.opacity(0.8))
                Spacer()
                Button { vm.peerMessage = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(vm.peerMessage)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                Button {
                    vm.sendPeerMessageToAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                        Text("Send to AI")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.75))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.15), value: vm.peerMessage)
    }

    // MARK: - Manual input

    private var manualInputRow: some View {
        HStack(spacing: 8) {
            TextField("Type your message…", text: $vm.manualInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { vm.sendToAI() }
            Button { vm.sendToAI() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundColor(vm.manualInput.isEmpty ? .secondary.opacity(0.3) : .primary)
            }
            .buttonStyle(.plain)
            .disabled(vm.manualInput.isEmpty)
            Button { vm.showManualInput = false; vm.manualInput = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Screenshot row

    private var screenshotRow: some View {
        HStack(spacing: 8) {
            if let img = vm.pendingScreenshot {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(height: 36).cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
            Text("Screenshot attached").font(.caption2).foregroundColor(.secondary)
            Spacer()
            Button { vm.pendingScreenshot = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - AI Response

    private var responseArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar with close button
            HStack {
                Text("Response")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.aiResponse.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.aiResponse, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response")
                }
                Button { vm.aiResponse = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                if vm.isSendingToAI {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.75)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else {
                    MarkdownResponseView(text: vm.aiResponse)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: 300)
            .animation(.easeInOut(duration: 0.2), value: vm.isSendingToAI)
        }
    }


    // MARK: - Calendar panel

    private var calendarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Upcoming", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.calendarAuthorized {
                    Button("Enable Calendar") { vm.requestCalendarAccess() }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                } else {
                    Button {
                        Task { await vm.calendarManager.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                Button { vm.showCalendarPanel = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if vm.calendarAuthorized {
                if vm.calendarEvents.isEmpty {
                    Text("No events in the next 24 hours")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                } else {
                    ForEach(vm.calendarEvents, id: \.eventIdentifier) { event in
                        CalendarEventRow(event: event)
                    }
                    .padding(.bottom, 6)
                }
            } else {
                Text("Grant calendar access to see your upcoming events and get personalised reminders.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Notes panel

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Session Notes", systemImage: "note.text")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !vm.sessionNotes.isEmpty {
                    Menu {
                        Button("Export Markdown") { vm.exportNotes(asMarkdown: true) }
                        Button("Export Plain Text") { vm.exportNotes(asMarkdown: false) }
                        Divider()
                        Button("Clear", role: .destructive) { vm.clearNotes() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.caption).foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { vm.showNotesPanel = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if vm.sessionNotes.isEmpty {
                Text("AI responses are saved here automatically. You can also save notes manually.")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.sessionNotes.reversed()) { note in
                            NoteEntryRow(note: note)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    // MARK: - Settings popover

    private var settingsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // ── Peer Control ──────────────────────────────────────────
                Text("Peer Control").font(.caption.weight(.semibold)).foregroundColor(.secondary)

                Toggle(isOn: $vm.peerControlEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Allow peer access")
                            .font(.caption)
                        Text("Lets a trusted colleague view your overlay and send messages to the AI")
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if vm.peerServer.isRunning {
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

                        // Connection URL row
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

                Divider()

                // User profile
                Text("Profile").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                profileField("Name", placeholder: "Your name",  text: $vm.userProfile.name)
                profileField("Role", placeholder: "Your role",  text: $vm.userProfile.currentRole)
                profileField("Company", placeholder: "Company", text: $vm.userProfile.company)

                Divider()

                // Recording
                Text("Recording").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Toggle(isOn: $vm.vadEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-send on silence")
                            .font(.caption)
                        Text("Sends after ~2s of silence while recording")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Divider()

                // Custom system prompt
                HStack {
                    Text("System Prompt").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Spacer()
                    if !vm.customSystemPrompt.isEmpty {
                        Button("Reset") { vm.customSystemPrompt = "" }
                            .font(.caption2).foregroundColor(.orange)
                            .buttonStyle(.plain)
                    }
                }
                Text("Overrides the mode's default prompt. Leave empty to use the \(vm.sessionMode.displayName) default.")
                    .font(.caption2).foregroundColor(.secondary)
                TextEditor(text: $vm.customSystemPrompt)
                    .font(.system(size: 11))
                    .frame(height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Divider()

                // Appearance
                Text("Appearance").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                sliderRow(icon: "sun.max",      label: "Opacity",     value: $vm.opacity,           range: 0.2...1.0)
                sliderRow(icon: "square.dashed", label: "Background", value: $vm.backgroundOpacity, range: 0.0...1.0,
                          display: { v in v == 0 ? "Off" : "\(Int(v * 100))%" })

                Divider()

                // API keys
                Text("API Keys").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                keyField(label: "Anthropic", placeholder: "sk-ant-api…", text: $vm.apiKey)
                keyField(label: "OpenAI",    placeholder: "sk-…",         text: $vm.openAIApiKey)
                keyField(label: "ElevenLabs", placeholder: "sk_…",         text: $vm.elevenLabsAPIKey)

                Divider()

                // Shortcuts
                Text("Shortcuts").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    shortcutRow("Ctrl+Opt+↑↓←→",  "Move")
                    shortcutRow("Ctrl+Shift+↑↓←→", "Resize")
                    shortcutRow("Ctrl+Opt+T",       "Toggle record + send")
                    shortcutRow("Ctrl+Opt+Y",       "Toggle record + send")
                    shortcutRow("Ctrl+Opt+S",       "Screenshot → AI")
                    shortcutRow("Ctrl+Opt+A",       "Send selected text to AI")
                    shortcutRow("Ctrl+Opt+C",       "Explain clipboard")
                    shortcutRow("Ctrl+Opt+Space",   "Toggle overlay")
                }
            }
            .padding(14)
        }
        .frame(minWidth: 280, maxHeight: 500)
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

    private func sliderRow(icon: String, label: String, value: Binding<Double>, range: ClosedRange<Double>, display: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundColor(.secondary).frame(width: 16)
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text(display?(value.wrappedValue) ?? "\(Int(value.wrappedValue * 100))%")
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private func keyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        KeyFieldView(label: label, placeholder: placeholder, text: text)
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.system(size: 10, design: .monospaced))
            Spacer()
            Text(desc).font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: - Calendar event row

struct CalendarEventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 10) {
            // Colour dot from calendar
            Circle()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Event")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(timeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(countdown)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isImminent ? .orange : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var timeLabel: String {
        guard let start = event.startDate else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(start) ? .none : .short
        return f.string(from: start)
    }

    private var countdown: String {
        guard let start = event.startDate else { return "" }
        let mins = Int(start.timeIntervalSinceNow / 60)
        if mins < 1    { return "now" }
        if mins < 60   { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    private var isImminent: Bool {
        guard let start = event.startDate else { return false }
        return start.timeIntervalSinceNow < 20 * 60
    }
}

// MARK: - Note entry row

struct NoteEntryRow: View {
    let note: NoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: note.source == .ai ? "sparkles" : "pencil")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(note.mode.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(note.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(note.content)
                .font(.system(size: 11))
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }
}

// MARK: - Key field with show/hide toggle

struct KeyFieldView: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundColor(.secondary)
            HStack(spacing: 4) {
                if visible {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                Button { visible.toggle() } label: {
                    Image(systemName: visible ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(visible ? "Hide" : "Show (enables paste)")
            }
        }
    }
}

// MARK: - Browser panel (tabs + split)

struct BrowserPanelView: View {
    @EnvironmentObject var vm: OverlayViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            splitContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(vm.browserTabs) { tab in
                        BrowserTabItemView(tab: tab)
                            .environmentObject(vm)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }

            Divider().frame(height: 16)

            // New tab
            Button { vm.addTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New tab (Google)")

            Divider().frame(height: 16)

            // Layout switcher
            HStack(spacing: 1) {
                layoutBtn(1, "rectangle")
                layoutBtn(2, "rectangle.split.2x1")
                layoutBtn(3, "rectangle.split.3x1")
            }
            .padding(.horizontal, 6)
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func layoutBtn(_ n: Int, _ icon: String) -> some View {
        Button {
            vm.splitCount = n
            while vm.browserTabs.count < n { vm.addTab() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(vm.splitCount == n ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(n == 1 ? "Single" : "Split \(n)")
    }

    // MARK: Split content

    @ViewBuilder
    private var splitContent: some View {
        let indices = displayIndices
        if indices.isEmpty {
            Color.clear.frame(height: 0)
        } else if indices.count == 1 {
            BrowserTabContentView(tab: $vm.browserTabs[indices[0]])
                .environmentObject(vm)
                .id(vm.browserTabs[indices[0]].id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ForEach(indices, id: \.self) { idx in
                    BrowserTabContentView(tab: $vm.browserTabs[idx])
                        .environmentObject(vm)
                        .id(vm.browserTabs[idx].id)
                        .frame(minWidth: 160, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var displayIndices: [Int] {
        let count = min(vm.splitCount, vm.browserTabs.count)
        guard count > 0 else { return [] }
        let activeIdx = vm.browserTabs.firstIndex(where: { $0.id == vm.activeTabID }) ?? 0
        let start = max(0, min(activeIdx, vm.browserTabs.count - count))
        return Array(start..<(start + count))
    }
}

// MARK: - Tab strip item

struct BrowserTabItemView: View {
    @EnvironmentObject var vm: OverlayViewModel
    let tab: BrowserTab

    private var isActive: Bool { vm.activeTabID == tab.id }

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title.isEmpty ? (tab.url.host ?? "Tab") : tab.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .leading)

            Button { vm.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.secondary.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { vm.activeTabID = tab.id }
    }
}

// MARK: - Individual tab content (URL bar + WebView)

struct BrowserTabContentView: View {
    @EnvironmentObject var vm: OverlayViewModel
    @Binding var tab: BrowserTab
    @State private var urlInput: String
    @StateObject private var webState = WebViewState()

    init(tab: Binding<BrowserTab>) {
        self._tab = tab
        _urlInput = State(initialValue: tab.wrappedValue.url.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 5) {
                Button { webState.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(webState.canGoBack ? .primary : .primary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!webState.canGoBack)

                Button { webState.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(webState.canGoForward ? .primary : .primary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!webState.canGoForward)

                Image(systemName: toolbarIcon)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                TextField("URL", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .onSubmit { navigate() }

                Button { navigate() } label: {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.06))

            Divider()

            WebPanelView(url: tab.url, tabID: tab.id, state: webState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tab.url) { newURL in
            urlInput = newURL.absoluteString
        }
        .onChange(of: webState.currentURL) { newURL in
            if !newURL.isEmpty { urlInput = newURL }
        }
        .onChange(of: webState.title) { newTitle in
            if !newTitle.isEmpty { tab.title = newTitle }
        }
    }

    private var toolbarIcon: String {
        if urlInput.contains("claude")  { return "sparkles" }
        if urlInput.contains("chatgpt") { return "bubble.left.fill" }
        if urlInput.contains("google")  { return "magnifyingglass" }
        return "globe"
    }

    private func navigate() {
        var raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        if let url = URL(string: raw) { tab.url = url }
    }
}

// MARK: - Waveform logo

struct WaveformLogo: View {
    @EnvironmentObject var vm: OverlayViewModel
    @State private var phases: [CGFloat] = [0, 0.4, 0.8, 0.5, 0.2]

    private let barCount = 5
    private let barWidth: CGFloat = 2.5
    private let spacing:  CGFloat = 2.0
    private let maxH:     CGFloat = 18
    private let minH:     CGFloat = 4
    private let idleHeights: [CGFloat] = [5, 10, 16, 10, 5]

    private var isActive: Bool { vm.isRecording || vm.isQuickAsking || vm.isDictating }

    private var barColor: Color {
        if vm.isDictating  { return .orange }
        if vm.isQuickAsking { return .red }
        return Color.primary.opacity(0.8)
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let h = isActive
                    ? minH + (maxH - minH) * abs(sin(phases[i] * .pi))
                    : idleHeights[i]
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(barColor)
                    .frame(width: barWidth, height: h)
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.4 + Double(i) * 0.07).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.3),
                        value: h
                    )
            }
        }
        .frame(height: maxH)
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            guard isActive else { return }
            for i in 0..<barCount {
                phases[i] = (phases[i] + CGFloat.random(in: 0.1...0.3)).truncatingRemainder(dividingBy: 2)
            }
        }
    }
}

// MARK: - Markdown response renderer

struct MarkdownResponseView: View {
    let text: String

    // Parsed block types
    private enum Block {
        case code(lang: String, body: String)
        case heading(level: Int, text: String)
        case bullet(String)
        case plain(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Parser

    private func parse() -> [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuf: [String] = []

        func flush() {
            let joined = textBuf.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.plain(joined)) }
            textBuf = []
        }

        while i < lines.count {
            let raw  = lines[i]
            let trim = raw.trimmingCharacters(in: .whitespaces)

            if trim.hasPrefix("```") {
                flush()
                let lang = String(trim.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(lines[i])
                    i += 1
                }
                result.append(.code(lang: lang, body: code.joined(separator: "\n")))
            } else if trim.hasPrefix("### ") {
                flush(); result.append(.heading(level: 3, text: String(trim.dropFirst(4))))
            } else if trim.hasPrefix("## ") {
                flush(); result.append(.heading(level: 2, text: String(trim.dropFirst(3))))
            } else if trim.hasPrefix("# ") {
                flush(); result.append(.heading(level: 1, text: String(trim.dropFirst(2))))
            } else if trim.hasPrefix("- ") || trim.hasPrefix("* ") || trim.hasPrefix("+ ") {
                flush(); result.append(.bullet(String(trim.dropFirst(2))))
            } else if let r = trim.range(of: #"^\d+\. "#, options: .regularExpression) {
                flush(); result.append(.bullet(String(trim[r.upperBound...])))
            } else if trim.isEmpty {
                flush()
            } else {
                textBuf.append(raw)
            }
            i += 1
        }
        flush()
        return result
    }

    // MARK: Renderers

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .textSelection(.enabled)
                }
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? 14 : level == 2 ? 13 : 12, weight: .semibold))

        case .bullet(let text):
            HStack(alignment: .top, spacing: 5) {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 10, alignment: .center)
                inlineText(text)
                    .font(.system(size: 12))
            }

        case .plain(let text):
            inlineText(text)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func inlineText(_ string: String) -> some View {
        if let attr = try? AttributedString(markdown: string) {
            Text(attr).textSelection(.enabled)
        } else {
            Text(string).textSelection(.enabled)
        }
    }
}

// MARK: - Resume builder panel

extension OverlayView {

    // Small floating pill shown in icon/collapsed mode
    var resumeFloatingPill: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Score row ──────────────────────────────────────────────
            if vm.isScoringResume {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text("Scoring resume…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if let sc = vm.resumeScore {
                scoreRow(sc)
            }

            // ── Divider between score and file ─────────────────────────
            if (vm.resumeScore != nil || vm.isScoringResume) &&
               (vm.resumeFileURL != nil || vm.isGeneratingResume) {
                Divider()
            }

            // ── File / generating row ──────────────────────────────────
            if vm.isGeneratingResume {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text("Generating resume…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if let url = vm.resumeFileURL {
                fileRow(url)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(vm.backgroundOpacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func scoreRow(_ sc: ResumeScore) -> some View {
        let scoreColor: Color = sc.score >= 80 ? .green : sc.score >= 60 ? .yellow : .red
        HStack(spacing: 10) {
            // Score ring
            ZStack {
                Circle()
                    .stroke(scoreColor.opacity(0.2), lineWidth: 3)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: CGFloat(sc.score) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
                Text("\(sc.score)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(scoreColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sc.verdict)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Text(sc.recommendation)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { vm.resumeScore = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Missing keywords chips
        if !sc.missing.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text("Missing:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(sc.missing, id: \.self) { kw in
                        Text(kw)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 0) {
            ZStack {
                FileDragView(fileURL: url)
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("Drag to upload")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(.leading, 12)
            .padding(.vertical, 8)

            Spacer()
            Divider().frame(height: 24)

            Button { ResumePreviewHelper.shared.show(url: url) } label: {
                Image(systemName: "eye")
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Preview")

            Button { vm.resumeFileURL = nil; vm.resumeOutput = "" } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 34)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.trailing, 4)
    }

    var resumePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Resume Builder", systemImage: "doc.badge.plus")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { vm.showResumeBuilder = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // ── Your resume (saved once, reused forever) ──────────────
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Your Resume")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if !vm.resumeBase.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Text("Saved — reused for every JD")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 12)
                inputSection(placeholder: "Paste your resume here once — it will be saved and reused for all future job descriptions",
                             text: $vm.resumeBase, height: vm.resumeBase.isEmpty ? 80 : 44)
            }

            // ── Job description (per-generation) ─────────────────────
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Job Description")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Ctrl+Opt+R — paste clipboard JD & generate")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 12)
                inputSection(placeholder: "Paste job description here, or copy it and press Ctrl+Opt+R from anywhere",
                             text: $vm.resumeJD, height: 80)
            }
            .padding(.top, 4)

            // Generate button
            HStack {
                Spacer()
                Button { vm.generateResume() } label: {
                    HStack(spacing: 6) {
                        if vm.isGeneratingResume { ProgressView().scaleEffect(0.65) }
                        Text(vm.isGeneratingResume ? "Generating…" : "Generate Resume")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        (vm.resumeJD.isEmpty || vm.resumeBase.isEmpty || vm.isGeneratingResume || vm.apiKey.isEmpty)
                            ? Color.secondary : Color.accentColor
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(vm.resumeJD.isEmpty || vm.resumeBase.isEmpty || vm.isGeneratingResume || vm.apiKey.isEmpty)
                Spacer()
            }
            .padding(.vertical, 8)

            // Score section
            if vm.isScoringResume || vm.resumeScore != nil {
                Divider()
                if vm.isScoringResume {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.65)
                        Text("Scoring…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                } else if let sc = vm.resumeScore {
                    scoreRow(sc)
                }
            }

            // Output section
            if !vm.resumeOutput.isEmpty || vm.isGeneratingResume {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Generated Resume")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        if !vm.resumeOutput.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vm.resumeOutput, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    if vm.isGeneratingResume && vm.resumeOutput.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Generating…").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    } else {
                        ScrollView {
                            Text(vm.resumeOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(minHeight: 100, maxHeight: 200)

                        // Draggable file badge — NSView drag source prevents window
                        // movement from stealing the gesture (isMovableByWindowBackground)
                        if let url = vm.resumeFileURL {
                            ZStack {
                                // NSView layer: owns the drag, blocks window movement
                                FileDragView(fileURL: url)
                                // Visual layer: non-interactive so events pass to NSView
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text("Drag into browser to upload")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "cursorarrow.and.square.on.square.dashed")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                            }
                            .background(Color.accentColor.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 10)

                            // Preview button
                            Button {
                                ResumePreviewHelper.shared.show(url: url)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "eye")
                                        .font(.system(size: 11))
                                    Text("Preview")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inputSection(placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 11))
                .frame(height: height)
                .scrollContentBackground(.hidden)
        }
        .padding(4)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
    }
}

// MARK: - File drag view (NSView-based so window movement doesn't steal the drag)

struct FileDragView: NSViewRepresentable {
    let fileURL: URL
    func makeNSView(context: Context) -> FileDragNSView { FileDragNSView() }
    func updateNSView(_ nsView: FileDragNSView, context: Context) { nsView.fileURL = fileURL }
}

class FileDragNSView: NSView, NSDraggingSource {
    var fileURL: URL?

    // Critical: prevents isMovableByWindowBackground from claiming this drag
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // Show the file's real Finder icon as the drag image
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: 40, height: 40), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

// MARK: - Quick Look preview helper

final class ResumePreviewHelper: NSObject, QLPreviewPanelDataSource {
    static let shared = ResumePreviewHelper()
    private var previewURL: URL?

    func show(url: URL) {
        previewURL = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL != nil ? 1 : 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

extension Notification.Name {
    static let captureScreenshot = Notification.Name("captureScreenshot")
}

// MARK: - Mode picker

extension OverlayView {

    private func modeColor(_ mode: SessionMode) -> Color {
        switch mode {
        case .general:   return .purple
        case .interview: return .green
        case .meeting:   return .blue
        case .call:      return .orange
        }
    }

    var modePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SessionMode.allCases, id: \.self) { mode in
                    let selected = vm.sessionMode == mode
                    Button {
                        vm.sessionMode = mode
                        if mode == .interview { vm.startInterviewSession() }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            showModePicker = false
                            expanded       = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(mode.displayName)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(selected ? .white : .primary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(
                            selected
                                ? modeColor(mode)
                                : Color.primary.opacity(0.08)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)

                Button {
                    vm.toggleQuickAsk()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { showModePicker = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quick Ask")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(vm.isQuickAsking ? .white : .primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(vm.isQuickAsking ? Color.red : Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .opacity(vm.backgroundOpacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Quick ask floating pill

extension OverlayView {

    var quickAskFloatingPill: some View {
        VStack(alignment: .leading, spacing: 0) {

            if vm.isQuickAskSending {
                // ── Thinking state ────────────────────────────────────────
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text("Thinking…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            } else if !vm.quickAskResponse.isEmpty {
                // ── Response state ────────────────────────────────────────
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .padding(.top, 1)
                    ScrollView {
                        MarkdownResponseView(text: vm.quickAskResponse)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 260)
                    Button { vm.dismissQuickAsk() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(vm.backgroundOpacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 420)
    }
}

