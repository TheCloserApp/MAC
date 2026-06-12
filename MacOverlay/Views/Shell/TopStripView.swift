import SwiftUI
import AppKit

/// Slim header strip inside the unified expanded panel. Always shows the
/// editable session title on the left, a session overflow menu, and a
/// chevron on the right that closes the body back to the bar-only layout.
struct TopStripView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingTitle = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            closeButton
            titleField
            Spacer()
            composeButton
            sessionMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var titleField: some View {
        if editingTitle {
            TextField("Session title", text: $draftTitle, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .frame(maxWidth: 320)
                .onExitCommand(perform: cancelEdit)
        } else {
            Button {
                draftTitle = vm.sessionStore.activeSession.displayTitle
                editingTitle = true
            } label: {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .help("Click to rename")
            }
            .buttonStyle(.plain)
        }
    }

    /// Header label — names the active surface so the user always knows
    /// what they're looking at.
    private var headerTitle: String {
        switch vm.primarySurface {
        case .chat?:      return vm.sessionStore.activeSession.displayTitle
        case .interview?:
            // Show the actual session title whenever a session is being
            // hosted (live OR resumed-from-History); only fall back to
            // the mode label when the setup form is on screen.
            return vm.interviewSurfaceShowsChat
                ? vm.sessionStore.activeSession.displayTitle
                : vm.interviewSurfaceMode.displayName
        case .sessions?:  return "History"
        case .resumes?:   return "Resumes"
        case .prompts?:   return "Prompts"
        case .calendar?:  return "Calendar"
        case .browser?:   return "Browser"
        case .settings?:  return "Settings"
        case .none:       return vm.sessionStore.activeSession.displayTitle
        }
    }

    /// Close the whole shell back to the collapsed brand pill — the
    /// reference UI's top-left ✕. The brand pill stays available to
    /// reopen, so this is a soft close, not a quit. Esc triggers it too,
    /// except while the title is being edited (Esc cancels the edit then).
    @ViewBuilder
    private var closeButton: some View {
        let button = Button {
            // Match the panel's easeOut resize curve — see surfaceButton
            // in InputBarView for the rationale (spring overshoot vs the
            // AppKit resize was visibly bouncing the bar).
            withAnimation(Design.Motion.expand) {
                vm.primarySurface = nil
                vm.shellStage = .pill
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")

        if editingTitle {
            button
        } else {
            button.keyboardShortcut(.cancelAction)
        }
    }

    /// Compose / new-chat button — the reference UI's top-right pencil.
    /// Context-aware: on the Interview surface it returns to the setup
    /// form; everywhere else it mints a fresh chat session.
    private var composeButton: some View {
        Button {
            if vm.primarySurface == .interview {
                vm.requestNewInterviewSession()
            } else {
                vm.startNewSession()
                withAnimation(Design.Motion.spring) {
                    vm.primarySurface = .chat
                }
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help(vm.primarySurface == .interview ? "New interview setup" : "New chat (⌘N)")
    }

    private var sessionMenu: some View {
        Menu {
            // Live-session controls first — pause/resume and End moved
            // here from the input bar so the bar stays minimal during
            // an interview.
            if vm.isInterviewSession {
                if !vm.isInterviewTextOnly {
                    Button {
                        if vm.isInterviewPaused {
                            vm.resumeInterviewSession()
                        } else {
                            vm.pauseInterviewSession()
                        }
                    } label: {
                        Label(vm.isInterviewPaused ? "Resume interview" : "Pause interview",
                              systemImage: vm.isInterviewPaused ? "play.fill" : "pause.fill")
                    }
                }
                Button(role: .destructive) {
                    vm.stopInterviewSession()
                } label: {
                    Label("End session", systemImage: "stop.circle")
                }
                Divider()
            }

            // Model picker — moved out of the bar; switching applies
            // from the next answer.
            Menu {
                let visibility = ModelVisibility.shared
                ForEach(["Anthropic", "OpenAI"], id: \.self) { provider in
                    let models = OverlayViewModel.availableModels
                        .filter { $0.provider == provider && visibility.isVisible($0.id) }
                    if !models.isEmpty {
                        Section(provider) {
                            ForEach(models, id: \.id) { m in
                                Button {
                                    vm.selectedModel = m.id
                                } label: {
                                    HStack {
                                        Text(m.name)
                                        if vm.selectedModel == m.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Model: \(currentModelName)", systemImage: "cpu")
            }

            Divider()

            Button {
                // Context-aware new session: on the Interview surface,
                // flip back to the setup form rather than minting a new
                // chat session right away. Elsewhere, behaves like before.
                if vm.primarySurface == .interview {
                    vm.requestNewInterviewSession()
                } else {
                    vm.startNewSession()
                    withAnimation(Design.Motion.spring) {
                        vm.primarySurface = .chat
                    }
                }
            } label: {
                Label(vm.primarySurface == .interview
                      ? "New interview setup"
                      : "New Session",
                      systemImage: "square.and.pencil")
            }.keyboardShortcut("n", modifiers: .command)

            Button {
                withAnimation(Design.Motion.spring) {
                    vm.primarySurface = .sessions
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

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
                    Button { vm.audioSource = src } label: {
                        HStack {
                            Text(src.label)
                            if vm.audioSource == src { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Audio source: \(vm.audioSource.label)", systemImage: "waveform")
            }

            // Quick transparency presets — reachable mid-interview so the
            // overlay can fade over the call window without a trip to
            // Preferences (which also has the fine-grained sliders).
            Menu {
                ForEach([1.0, 0.85, 0.7, 0.55, 0.4], id: \.self) { level in
                    Button {
                        vm.opacity = level
                    } label: {
                        HStack {
                            Text("\(Int(level * 100))%")
                            if abs(vm.opacity - level) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Transparency: \(Int(vm.opacity * 100))%",
                      systemImage: "circle.lefthalf.filled")
            }

            Menu {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.2], id: \.self) { level in
                    Button {
                        vm.backgroundOpacity = level
                    } label: {
                        HStack {
                            Text("\(Int(level * 100))%")
                            if abs(vm.backgroundOpacity - level) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Background: \(Int(vm.backgroundOpacity * 100))%",
                      systemImage: "rectangle.on.rectangle")
            }

            // Which speech engine is doing the transcribing — switchable
            // here so the strip doesn't need a badge for it.
            Menu {
                ForEach(OverlayViewModel.TranscriptionPreference.allCases) { pref in
                    Button {
                        vm.transcriptionPreference = pref
                    } label: {
                        HStack {
                            Text(pref.displayName)
                            if vm.transcriptionPreference == pref {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Transcription: \(vm.transcriptionBackend.rawValue)",
                      systemImage: "waveform.badge.mic")
            }

            if vm.isInterviewSession && !vm.isInterviewTextOnly {
                Divider()

                Button {
                    vm.showLiveTranscript.toggle()
                } label: {
                    HStack {
                        Text("Show live transcript")
                        if vm.showLiveTranscript { Image(systemName: "checkmark") }
                    }
                }

                Button {
                    vm.interviewFocusMode.toggle()
                } label: {
                    HStack {
                        Text("Focus mode (current Q&A only)")
                        if vm.interviewFocusMode { Image(systemName: "checkmark") }
                    }
                }
            }

            if vm.showTokenCounts {
                Divider()
                let s = vm.sessionStore.activeSession
                Text("\(s.totalInputTokens) in · \(s.totalOutputTokens) out · \(s.totalTokens) total")
            }

            Divider()

            Button(role: .destructive) {
                vm.sessionStore.delete(id: vm.sessionStore.activeSessionID)
            } label: {
                Label("Delete Session", systemImage: "trash")
            }

            Divider()

            // App-level controls — there's no menu-bar icon (it would be
            // visible to others during screen shares), so these live here.
            Button {
                (NSApp.delegate as? AppDelegate)?.resetPosition()
            } label: {
                Label("Reset overlay position", systemImage: "arrow.uturn.backward")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit MacOverlay", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.04)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentModelName: String {
        OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model"
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
}
