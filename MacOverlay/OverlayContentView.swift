import SwiftUI
import EventKit

struct OverlayView: View {
    @EnvironmentObject var vm: OverlayViewModel
    @State private var showSettingsPopover = false
    @State private var dotVisible = true
    @State private var expanded = false

    private var hasContent: Bool {
        vm.isRecording || !vm.transcription.isEmpty
            || vm.showManualInput
            || vm.pendingScreenshot != nil
            || vm.isSendingToAI || !vm.aiResponse.isEmpty
            || vm.showNotesPanel
            || vm.showCalendarPanel
            || vm.webURL != nil
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
                // ── Collapsed: just the logo ──────────────────────────
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { expanded = true } } label: {
                    WaveformLogo()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial)
                                .opacity(vm.backgroundOpacity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            // ── Content panel ─────────────────────────────────────────
            if expanded && hasContent {
                VStack(spacing: 0) {
                    if vm.isRecording || !vm.transcription.isEmpty {
                        transcriptionRow
                        if hasMoreBelowTranscription { Divider() }
                    }
                    if vm.isRecording || !vm.transcription.isEmpty {
                        quickActionBar
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
                    if let url = vm.webURL {
                        Divider()
                        webPanel(url: url)
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .opacity(vm.backgroundOpacity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(0)
        .onReceive(
            Timer.publish(every: 0.6, on: .main, in: .common)
                .autoconnect()
                .filter { _ in vm.isRecording }
        ) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { dotVisible.toggle() }
        }
        .onChange(of: vm.isRecording) { if !$0 { dotVisible = true } }
    }

    private var hasMoreBelowTranscription: Bool {
        vm.showManualInput || vm.pendingScreenshot != nil
            || vm.isSendingToAI || !vm.aiResponse.isEmpty
            || vm.showCalendarPanel || vm.showNotesPanel
    }

    // MARK: - Bar

    private var bar: some View {
        HStack(alignment: .center, spacing: 10) {

            // Collapse button (logo acts as toggle)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { expanded = false }
            } label: {
                WaveformLogo()
            }
            .buttonStyle(.plain)

            Divider().frame(height: 14)

            // LEFT: dot + source + record
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(vm.isRecording ? (dotVisible ? 1 : 0) : 0)

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

                Divider().frame(height: 14)

                // Calendar
                barIcon("calendar", active: vm.showCalendarPanel) { vm.showCalendarPanel.toggle() }
                    .help("Calendar")

                // Embedded browser
                Menu {
                    Button {
                        vm.webURL = vm.webURL?.absoluteString == "https://claude.ai" ? nil : URL(string: "https://claude.ai")
                    } label: {
                        Label("Claude", systemImage: "sparkles")
                    }
                    Button {
                        vm.webURL = vm.webURL?.absoluteString == "https://chatgpt.com" ? nil : URL(string: "https://chatgpt.com")
                    } label: {
                        Label("ChatGPT", systemImage: "bubble.left.fill")
                    }
                    if vm.webURL != nil {
                        Divider()
                        Button("Close") { vm.webURL = nil }
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(vm.webURL != nil ? .primary : .primary.opacity(0.7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open AI site in overlay")

                // Notes
                barIcon("note.text", active: vm.showNotesPanel) { vm.showNotesPanel.toggle() }
                    .help("Session notes")

                // Manual input
                barIcon("keyboard", active: vm.showManualInput) { vm.showManualInput.toggle() }
                    .help("Type a message")

                // Screenshot
                barIcon("camera.fill", active: vm.pendingScreenshot != nil) {
                    NotificationCenter.default.post(name: .captureScreenshot, object: nil)
                }
                .help("Attach screenshot (Ctrl+Opt+S)")

                // Send
                Button { vm.sendToAI() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundColor(vm.canSend ? .primary : .primary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSend)
                .help("Send to AI")

                // Settings
                Button { showSettingsPopover.toggle() } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                        .foregroundColor(vm.needsKeyForCurrentModel ? .orange : .primary)
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
                    Button(action.label) {
                        vm.selectQuickAction(action)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Transcription row

    private var transcriptionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                Text(vm.transcription.isEmpty ? "Listening…" : vm.transcription)
                    .font(.system(size: 12))
                    .foregroundStyle(vm.transcription.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)

            if !vm.transcription.isEmpty {
                Button { vm.transcription = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            ScrollView {
                if vm.isSendingToAI {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Thinking…").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                } else {
                    Text(vm.aiResponse)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
            }
            .frame(maxHeight: 200)
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

                // User profile
                Text("Profile").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                profileField("Name", placeholder: "Your name",  text: $vm.userProfile.name)
                profileField("Role", placeholder: "Your role",  text: $vm.userProfile.currentRole)
                profileField("Company", placeholder: "Company", text: $vm.userProfile.company)

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

                Divider()

                // Shortcuts
                Text("Shortcuts").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    shortcutRow("Ctrl+Opt+↑↓←→",  "Move")
                    shortcutRow("Ctrl+Shift+↑↓←→", "Resize")
                    shortcutRow("Ctrl+Opt+S",       "Screenshot → AI")
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
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundColor(.secondary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
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

// MARK: - Web panel

extension OverlayView {
    func webPanel(url: URL) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                // Site label
                HStack(spacing: 4) {
                    Image(systemName: url.host?.contains("claude") == true ? "sparkles" : "bubble.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                // Swap site
                Button {
                    if url.host?.contains("claude") == true {
                        vm.webURL = URL(string: "https://chatgpt.com")
                    } else {
                        vm.webURL = URL(string: "https://claude.ai")
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Switch site")

                // Close
                Button { vm.webURL = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            WebPanelView(url: url)
                .frame(height: 420)
        }
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

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let h = vm.isRecording
                    ? minH + (maxH - minH) * abs(sin(phases[i] * .pi))
                    : idleHeights[i]
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: barWidth, height: h)
                    .animation(
                        vm.isRecording
                            ? .easeInOut(duration: 0.4 + Double(i) * 0.07).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.3),
                        value: h
                    )
            }
        }
        .frame(height: maxH)
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            guard vm.isRecording else { return }
            for i in 0..<barCount {
                phases[i] = (phases[i] + CGFloat.random(in: 0.1...0.3)).truncatingRemainder(dividingBy: 2)
            }
        }
    }
}

extension Notification.Name {
    static let captureScreenshot = Notification.Name("captureScreenshot")
}
