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
    /// reopen, so this is a soft close, not a quit.
    private var closeButton: some View {
        Button {
            // Match the panel's easeOut resize curve — see surfaceButton
            // in InputBarView for the rationale (spring overshoot vs the
            // AppKit resize was visibly bouncing the bar).
            withAnimation(Design.Motion.expand) {
                vm.primarySurface = nil
                vm.shellStage = .pill
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Close")
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
