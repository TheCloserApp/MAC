import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Primary surface for the Interview flow. Two states:
///   - `vm.isInterviewSession == false` → setup form (pick new/previous
///     session, optional resume, optional context, system prompt, Start).
///   - `vm.isInterviewSession == true`  → live interview view — reuses
///     `ChatSurfaceView` so the running session looks identical to the
///     chat surface (transcript strip + Live Focus card / bubbles).
struct InterviewSurfaceView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Group {
            if vm.interviewSurfaceShowsChat {
                ChatSurfaceView()
            } else {
                setupForActiveMode
            }
        }
    }

    /// Pick the setup form by mode tab. Both forms render a shared mode
    /// bar at the top so toggling between them feels like swapping tabs
    /// rather than navigating to a new screen.
    @ViewBuilder
    private var setupForActiveMode: some View {
        switch vm.interviewSurfaceMode {
        case .interview:   InterviewSetupForm()
        case .regularCall: RegularCallSetupForm()
        }
    }
}

// MARK: - Mode bar (shared header)

/// Pills at the top of either setup form: Interview / Regular call.
/// Toggles `vm.interviewSurfaceMode` which drives both the setup body
/// and the kind of session that gets resumed when the user re-enters
/// the surface.
private struct InterviewModeBar: View {
    @Environment(OverlayViewModel.self) private var vm

    private let modes = OverlayViewModel.InterviewSurfaceMode.available

    var body: some View {
        if modes.count > 1 {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    vm.switchInterviewSurfaceMode(mode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(vm.interviewSurfaceMode == mode ? Design.Ink.inverse : Design.Ink.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(
                        vm.interviewSurfaceMode == mode
                        ? Design.Ink.primary
                        : Design.Surface.controlFill
                    ))
                    .overlay(Capsule().strokeBorder(
                        vm.interviewSurfaceMode == mode
                        ? Color.white.opacity(0.22)
                        : Design.Surface.hairline,
                        lineWidth: 0.5
                    ))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Setup form

private struct InterviewSetupForm: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showCreatePrompt = false
    @State private var newPromptName    = ""
    @State private var newPromptContent = ""

    var body: some View {
        @Bindable var vm = vm
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InterviewModeBar()
                header
                sessionPicker
                languagePicker
                resumePicker
                contextEditor
                promptPicker
                autoGenerateRow
                startRow
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .hiddenScrollGutter()
        .sheet(isPresented: $showCreatePrompt) {
            createPromptSheet
        }
    }

    /// Auto-generate suggestion checkbox. When ON, the AI streams a
    /// suggested response into the chat as the interview transcript
    /// updates. When OFF, the user controls send via the bar's Send
    /// button — useful when the interviewer is still mid-question.
    private var autoGenerateRow: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Toggle(isOn: $vm.interviewAutoGenerate) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Design.Ink.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-generate responses")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Answers each real question as it's asked.")
                            .font(.system(size: 10))
                            .foregroundColor(Design.Ink.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
        }
    }

    // MARK: Sections

    private var header: some View {
        Text("Set up your interview")
            .font(.system(size: 18, weight: .semibold))
    }

    private var languagePicker: some View {
        sectionCard(title: "Language", systemImage: "character.bubble") {
            TranscriptionLanguagePicker()
        }
    }

    private var sessionPicker: some View {
        sectionCard(title: "Session", systemImage: "rectangle.on.rectangle") {
            HStack(spacing: 6) {
                segmentChip(
                    title: "New interview",
                    icon: "plus.circle",
                    selected: vm.interviewResumeSessionID == nil
                ) {
                    vm.interviewResumeSessionID = nil
                }

                Menu {
                    Button("New interview") {
                        vm.interviewResumeSessionID = nil
                    }
                    Divider()
                    let recents = vm.sessionStore.sortedSessions.prefix(20)
                    if recents.isEmpty {
                        Text("No past sessions yet").font(.caption)
                    } else {
                        ForEach(Array(recents), id: \.id) { s in
                            Button(s.displayTitle) {
                                vm.interviewResumeSessionID = s.id
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text(previousSessionLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Design.Ink.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(
                        vm.interviewResumeSessionID == nil
                        ? Design.Surface.controlFill
                        : Design.Surface.raisedFill
                    ))
                    .overlay(Capsule().strokeBorder(
                        vm.interviewResumeSessionID == nil
                        ? Design.Surface.hairline
                        : Color.white.opacity(0.22),
                        lineWidth: 0.5
                    ))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var previousSessionLabel: String {
        if let id = vm.interviewResumeSessionID,
           let s = vm.sessionStore.sessions.first(where: { $0.id == id }) {
            return s.displayTitle
        }
        return "Previous session…"
    }

    private var resumePicker: some View {
        sectionCard(title: "Resume", systemImage: "doc.richtext", optional: true) {
            HStack(spacing: 8) {
                if let url = vm.interviewResumeFileURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Design.Ink.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            vm.interviewResumeFileURL = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Design.Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove resume")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Design.Surface.controlFill))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }

                Button {
                    pickResumeFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                        Text(vm.interviewResumeFileURL == nil ? "Upload file" : "Replace…")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("PDF · DOCX · RTF · TXT · MD")

                // Resume text is extracted in the background the moment the
                // file is picked, so Start doesn't block on parsing.
                if vm.interviewResumeFileURL != nil {
                    if vm.isPreparingResume {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Reading…")
                                .font(.system(size: 11))
                                .foregroundColor(Design.Ink.secondary)
                        }
                    } else if !vm.interviewResumeText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                            Text("Ready")
                                .font(.system(size: 11))
                                .foregroundColor(Design.Ink.secondary)
                        }
                    }
                }

                Spacer()
            }
        }
    }

    private var contextEditor: some View {
        @Bindable var vm = vm
        return sectionCard(title: "Context", systemImage: "text.alignleft", optional: true) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Design.Surface.inputFill)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                    TextEditor(text: $vm.interviewContext)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 12))
                        .padding(8)
                        .frame(minHeight: 80, maxHeight: 140)
                    if vm.interviewContext.isEmpty {
                        Text("Role, company, JD, talking points…")
                            .font(.system(size: 12))
                            .foregroundColor(Design.Ink.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

                contextFilesRow
            }
        }
    }

    /// "Attach files" button + chip list for extra context files (JD PDF,
    /// notes, briefing docs). Their extracted text rides as a pending
    /// attachment on the interview's first user turn — same as the resume.
    private var contextFilesRow: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { pickContextFiles() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11, weight: .medium))
                        Text(vm.interviewContextFiles.isEmpty
                             ? "Attach files"
                             : "Attach more")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("PDF · DOCX · RTF · TXT · MD — text is extracted and sent as context.")

                Spacer()
            }

            if !vm.interviewContextFiles.isEmpty {
                FlowChipList(files: vm.interviewContextFiles) { id in
                    vm.interviewContextFiles.removeAll { $0.id == id }
                }
            }
        }
    }

    private func pickContextFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // Skip duplicates (same URL already attached).
            if vm.interviewContextFiles.contains(where: { $0.url == url }) { continue }
            let text = (try? ResumeImporter.importFile(url: url)) ?? ""
            guard !text.isEmpty else { continue }
            vm.interviewContextFiles.append(
                .init(url: url, name: url.lastPathComponent, extractedText: text)
            )
        }
    }

    private var promptPicker: some View {
        sectionCard(title: "System prompt", systemImage: "text.bubble") {
            HStack(spacing: 6) {
                Menu {
                    Button {
                        vm.promptStore.activePresetID = nil
                    } label: {
                        HStack {
                            Text("Default (Interview)")
                            if vm.promptStore.activePresetID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    let conversation = vm.promptStore.conversationPresets
                    if !conversation.isEmpty {
                        Divider()
                        ForEach(conversation) { p in
                            Button {
                                vm.promptStore.activePresetID = p.id
                            } label: {
                                HStack {
                                    Text(p.name)
                                    if vm.promptStore.activePresetID == p.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Design.Ink.secondary)
                        Text(activePromptName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Design.Ink.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    newPromptName = ""
                    newPromptContent = ""
                    showCreatePrompt = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Create new")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Save a new system prompt and use it")

                Spacer()
            }
        }
    }

    private var activePromptName: String {
        vm.promptStore.activePreset?.name ?? "Default (Interview)"
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.missingRequiredKeys.isEmpty {
                MissingKeyWarning()
            }
            ProUsageNotice()
            HStack {
                Spacer()
                Button {
                    vm.beginInterviewFromSetup()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Start interview")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(Design.Ink.inverse)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Design.Ink.primary))
                    .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!vm.missingRequiredKeys.isEmpty)
                .opacity(vm.missingRequiredKeys.isEmpty ? 1 : 0.45)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start interview (⌘↩)")
                // Fresh usage for the Pro notice above.
                .task { await ProAccount.shared.refreshUsage() }
            }
        }
    }

    // MARK: Create-prompt sheet

    private var createPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New system prompt")
                .font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $newPromptName)
                .textFieldStyle(.roundedBorder)
            Text("Prompt").font(.caption).foregroundColor(Design.Ink.secondary)
            TextEditor(text: $newPromptContent)
                .font(.system(size: 12))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Cancel") { showCreatePrompt = false }
                Button("Save") {
                    let trimmedName = newPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedContent = newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedContent.isEmpty else { return }
                    let preset = vm.promptStore.add(
                        name: trimmedName,
                        content: trimmedContent,
                        kind: .conversation
                    )
                    vm.promptStore.activePresetID = preset.id
                    showCreatePrompt = false
                }
                .keyboardShortcut(.return)
                .disabled(
                    newPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    // MARK: Helpers

    private func pickResumeFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            vm.interviewResumeFileURL = url
        }
    }

    // MARK: Card scaffold

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        optional: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                if optional {
                    Text("Optional")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Design.Surface.controlFill))
                }
            }
            content()
        }
    }

    private func segmentChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selected ? Design.Ink.inverse : Design.Ink.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Design.Ink.primary : Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(
                selected ? Color.white.opacity(0.22) : Design.Surface.hairline,
                lineWidth: 0.5
            ))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Regular call setup form

/// Lighter setup form for the "Regular call" mode tab. No resume, no JD —
/// just a system prompt picker, free-text + file context, and a Call/Chat
/// toggle that picks between starting a live mic session (Call) or a
/// text-only chat (Chat).
private struct RegularCallSetupForm: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showCreatePrompt = false
    @State private var newPromptName    = ""
    @State private var newPromptContent = ""

    var body: some View {
        @Bindable var vm = vm
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InterviewModeBar()
                header
                contextEditor
                promptPicker
                modeToggleRow
                if vm.regularCallAsCall { languagePicker }
                startRow
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .hiddenScrollGutter()
        .sheet(isPresented: $showCreatePrompt) {
            createPromptSheet
        }
    }

    private var header: some View {
        Text("Set up a call")
            .font(.system(size: 18, weight: .semibold))
    }

    private var languagePicker: some View {
        sectionCard(title: "Language", systemImage: "character.bubble") {
            TranscriptionLanguagePicker()
        }
    }

    /// Re-uses the same Context section layout as the interview form so
    /// the two tabs look consistent. Free-text on top, attached files
    /// below as chips.
    private var contextEditor: some View {
        @Bindable var vm = vm
        return sectionCard(title: "Context", systemImage: "text.alignleft", optional: true) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Design.Surface.inputFill)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                    TextEditor(text: $vm.interviewContext)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 12))
                        .padding(8)
                        .frame(minHeight: 80, maxHeight: 140)
                    if vm.interviewContext.isEmpty {
                        Text("Who is the call with? What's the goal? Any background…")
                            .font(.system(size: 12))
                            .foregroundColor(Design.Ink.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 6) {
                    Button { pickContextFiles() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 11, weight: .medium))
                            Text(vm.interviewContextFiles.isEmpty ? "Attach files" : "Attach more")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Design.Surface.controlFill))
                        .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("PDF · DOCX · RTF · TXT · MD — text extracted into context.")
                    Spacer()
                }

                if !vm.interviewContextFiles.isEmpty {
                    FlowChipList(files: vm.interviewContextFiles) { id in
                        vm.interviewContextFiles.removeAll { $0.id == id }
                    }
                }
            }
        }
    }

    private var promptPicker: some View {
        sectionCard(title: "System prompt", systemImage: "text.bubble") {
            HStack(spacing: 6) {
                Menu {
                    Button {
                        vm.promptStore.activePresetID = nil
                    } label: {
                        HStack {
                            Text("Default (Call)")
                            if vm.promptStore.activePresetID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    let conversation = vm.promptStore.conversationPresets
                    if !conversation.isEmpty {
                        Divider()
                        ForEach(conversation) { p in
                            Button {
                                vm.promptStore.activePresetID = p.id
                            } label: {
                                HStack {
                                    Text(p.name)
                                    if vm.promptStore.activePresetID == p.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Design.Ink.secondary)
                        Text(vm.promptStore.activePreset?.name ?? "Default (Call)")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Design.Ink.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    newPromptName = ""
                    newPromptContent = ""
                    showCreatePrompt = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Create new")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Design.Surface.controlFill))
                    .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
    }

    /// Call vs Chat segmented control. Call = live mic + transcription
    /// (same engine as Interview, just with a different system prompt).
    /// Chat = text-only, the user types in the bar.
    private var modeToggleRow: some View {
        @Bindable var vm = vm
        return sectionCard(title: "Mode", systemImage: "waveform.circle") {
            HStack(spacing: 6) {
                segmentChip(title: "Call (live)",
                            icon: "phone.fill",
                            selected: vm.regularCallAsCall) {
                    vm.regularCallAsCall = true
                }
                segmentChip(title: "Chat (text)",
                            icon: "bubble.left.and.bubble.right.fill",
                            selected: !vm.regularCallAsCall) {
                    vm.regularCallAsCall = false
                }
                Spacer()
            }
        }
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.missingRequiredKeys.isEmpty {
                MissingKeyWarning()
            }
            ProUsageNotice()
            startButtonRow
        }
    }

    private var startButtonRow: some View {
        HStack {
            Spacer()
            Button {
                vm.beginRegularCallFromSetup()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: vm.regularCallAsCall ? "phone.fill" : "paperplane.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(vm.regularCallAsCall ? "Start call" : "Start chat")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(Design.Ink.inverse)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Design.Ink.primary))
                .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!vm.missingRequiredKeys.isEmpty)
            .opacity(vm.missingRequiredKeys.isEmpty ? 1 : 0.45)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Start (⌘↩)")
            // Fresh usage for the Pro notice above.
            .task { await ProAccount.shared.refreshUsage() }
        }
    }

    private var createPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New system prompt")
                .font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $newPromptName)
                .textFieldStyle(.roundedBorder)
            Text("Prompt").font(.caption).foregroundColor(Design.Ink.secondary)
            TextEditor(text: $newPromptContent)
                .font(.system(size: 12))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Cancel") { showCreatePrompt = false }
                Button("Save") {
                    let trimmedName = newPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedContent = newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty, !trimmedContent.isEmpty else { return }
                    let preset = vm.promptStore.add(
                        name: trimmedName,
                        content: trimmedContent,
                        kind: .conversation
                    )
                    vm.promptStore.activePresetID = preset.id
                    showCreatePrompt = false
                }
                .keyboardShortcut(.return)
                .disabled(
                    newPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func pickContextFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if vm.interviewContextFiles.contains(where: { $0.url == url }) { continue }
            let text = (try? ResumeImporter.importFile(url: url)) ?? ""
            guard !text.isEmpty else { continue }
            vm.interviewContextFiles.append(
                .init(url: url, name: url.lastPathComponent, extractedText: text)
            )
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        optional: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                if optional {
                    Text("Optional")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Design.Surface.controlFill))
                }
            }
            content()
        }
    }

    private func segmentChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selected ? Design.Ink.inverse : Design.Ink.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Design.Ink.primary : Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(
                selected ? Color.white.opacity(0.22) : Design.Surface.hairline,
                lineWidth: 0.5
            ))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Missing-key warning

/// Amber banner shown above Start when the selected model has no API key
/// configured. Without it, the session starts, the mic records, and every
/// answer silently never arrives — the single most confusing failure a
/// new user can hit. Tapping it jumps straight to the key fields.
private struct MissingKeyWarning: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Button {
            vm.primarySurface = .settings
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Accent.amber)
                Text("Add your \(vm.missingRequiredKeys.joined(separator: " and ")) key\(vm.missingRequiredKeys.count > 1 ? "s" : "") to start. Click to open API keys.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Design.Accent.amber.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Design.Accent.amber.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Profile → API keys")
    }
}

// MARK: - Context-file chip list

/// Simple wrapping chip list for attached interview-context files. Each chip
/// shows a file-type icon, the filename (truncated middle), and an `x` to
/// remove. Wraps to multiple lines when the file count exceeds row width.
private struct FlowChipList: View {
    let files: [OverlayViewModel.InterviewContextFile]
    let onRemove: (UUID) -> Void

    var body: some View {
        // Lightweight wrap layout: VStack of HStacks built greedily by
        // estimated width. Keeps the dependency footprint low (no custom
        // Layout) and the file counts are small.
        let rows = pack(files, perRow: 3)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(rows[i]) { f in chip(f) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(_ f: OverlayViewModel.InterviewContextFile) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconFor(f.name))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
            Text(f.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Design.Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove(f.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.Ink.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.Surface.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
        )
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":          return "doc.richtext.fill"
        case "docx", "doc":  return "doc.text.fill"
        case "rtf":          return "doc.text.fill"
        case "md", "txt":    return "doc.plaintext.fill"
        default:             return "doc.fill"
        }
    }

    private func pack(_ items: [OverlayViewModel.InterviewContextFile],
                      perRow: Int) -> [[OverlayViewModel.InterviewContextFile]] {
        guard perRow > 0 else { return [items] }
        var out: [[OverlayViewModel.InterviewContextFile]] = []
        var bucket: [OverlayViewModel.InterviewContextFile] = []
        for f in items {
            bucket.append(f)
            if bucket.count == perRow {
                out.append(bucket); bucket.removeAll()
            }
        }
        if !bucket.isEmpty { out.append(bucket) }
        return out
    }
}
