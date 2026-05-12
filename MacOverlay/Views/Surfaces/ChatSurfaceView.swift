import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Default primary surface. Shows the active session as chat bubbles with
/// live transcription pinned at top while recording. Empty state offers
/// mode-specific starters so the user knows what to do.
struct ChatSurfaceView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var isDropTargeted = false

    var body: some View {
        let session = vm.sessionStore.activeSession
        VStack(spacing: 0) {
            if vm.sessionMode == .interview && (vm.isInterviewSession || vm.isRecording) {
                InterviewHUD()
                Divider().opacity(0.4)
            }
            content(session: session)
        }
            .overlay {
                if isDropTargeted {
                    dropOverlay
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Design.Radius.lg)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.lg)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay {
                VStack(spacing: Design.Space.sm) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26, weight: .medium))
                    Text("Drop to attach")
                        .font(Design.Font.title)
                    Text("PDF · DOCX · RTF · TXT · MD · image")
                        .font(Design.Font.small)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.accentColor)
            }
            .padding(Design.Space.sm)
            .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Files on disk arrive as URLs
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    attachDroppedFile(url: url)
                }
            }
            return true
        }

        // In-memory image drops (e.g. from Preview, Photos)
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                guard let image = img as? NSImage else { return }
                DispatchQueue.main.async {
                    vm.pendingScreenshot = image
                }
            }
            return true
        }
        return false
    }

    private func attachDroppedFile(url: URL) {
        let ext = url.pathExtension.lowercased()

        // Images → pending screenshot
        if ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic"].contains(ext) {
            if let img = NSImage(contentsOf: url) {
                vm.pendingScreenshot = img
            } else {
                vm.statusMessage = "Could not read image"
            }
            return
        }

        // Documents → extract text, append to input
        if ResumeImporter.supportedExtensions.contains(ext) {
            do {
                let text = try ResumeImporter.importFile(url: url)
                let name = url.lastPathComponent
                let prefix = vm.manualInput.isEmpty ? "" : "\n\n"
                vm.showManualInput = true
                vm.manualInput += "\(prefix)[Attached \(name)]\n\n\(text)"
            } catch {
                vm.statusMessage = "Error reading \(url.lastPathComponent): \(error.localizedDescription)"
            }
            return
        }

        vm.statusMessage = "Unsupported file type: .\(ext)"
    }

    @ViewBuilder
    private func content(session: ChatSession) -> some View {
        VStack(spacing: 0) {
            if vm.isRecording || vm.isInterviewSession || !vm.transcription.isEmpty {
                liveTranscriptStrip
                Divider().opacity(0.4)
            }

            if !vm.peerMessage.isEmpty {
                PeerMessagePanelView()
                Divider().opacity(0.4)
            }

            // Always show error-shaped status messages inline so the user
            // sees e.g. missing permissions or key setup issues. Regular
            // "Recording" / "Starting..." status is suppressed when recording
            // so it doesn't duplicate the live strip.
            if !vm.statusMessage.isEmpty
                && (vm.statusMessage.hasPrefix("Error")
                    || vm.statusMessage.hasPrefix("Screen Recording")
                    || (!vm.isRecording && !vm.isInterviewSession && vm.transcription.isEmpty)) {
                StatusRowView()
                Divider().opacity(0.4)
            }

            if session.turns.isEmpty && !vm.isSendingToAI && vm.aiResponse.isEmpty {
                emptyState
            } else {
                conversationView(session: session)
            }
        }
    }

    // MARK: - Live transcript

    private var liveTranscriptStrip: some View {
        HStack(alignment: .top, spacing: Design.Space.md) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundColor(vm.isInterviewSession ? .green : .red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(placeholderOrTranscription)
                        .font(Design.Font.body)
                        .foregroundStyle(vm.transcription.isEmpty
                                         ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(.primary))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .animation(.easeInOut(duration: 0.12), value: vm.transcription)
                    Spacer(minLength: 6)
                    backendBadge
                }

                if vm.isSendingToAI {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                        Text("Mic still on — keep speaking and it'll transcribe in the background.")
                            .font(Design.Font.micro)
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, Design.Space.lg)
        .padding(.vertical, Design.Space.md)
        .background(
            (vm.isRecording || vm.isInterviewSession)
                ? Color.red.opacity(0.03)
                : Color.primary.opacity(0.03)
        )
    }

    private var backendBadge: some View {
        let isEleven = vm.transcriptionBackend == .elevenLabs
        return HStack(spacing: 3) {
            Image(systemName: isEleven ? "bolt.fill" : "apple.logo")
                .font(.system(size: 8))
            Text(vm.transcriptionBackend.rawValue)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(isEleven ? .accentColor : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((isEleven ? Color.accentColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
        .help(isEleven
              ? "Using ElevenLabs scribe for live transcription."
              : "Using Apple on-device speech recognition. Add an ElevenLabs key in Preferences for higher accuracy.")
    }

    private var placeholderOrTranscription: String {
        if !vm.transcription.isEmpty { return vm.transcription }
        if vm.isInterviewSession     { return "Listening… speak anytime." }
        if vm.isRecording            { return "Listening…" }
        return "—"
    }

    // MARK: - Empty state (mode-aware starter cards)

    private var emptyState: some View {
        VStack(spacing: Design.Space.lg) {
            heroHeader
            starterCards
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Design.Space.xl)
    }

    private var heroHeader: some View {
        VStack(spacing: Design.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.accentColor, .purple],
                                                 startPoint: .top, endPoint: .bottom))
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .padding(.bottom, 2)

            Text(modeHeadline)
                .font(Design.Font.hero)
            Text(modeSubtitle)
                .font(Design.Font.small)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var starterCards: some View {
        let cards = starters
        VStack(spacing: Design.Space.sm) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                starterCard(title: card.title, subtitle: card.subtitle, prompt: card.prompt)
            }
        }
    }

    private func starterCard(title: String, subtitle: String, prompt: String) -> some View {
        @Bindable var vm = vm
        return Button {
            vm.showManualInput = true
            vm.manualInput = prompt
        } label: {
            HStack(alignment: .top, spacing: Design.Space.md) {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Design.Font.bodyBold).foregroundColor(.primary)
                    Text(subtitle).font(Design.Font.small).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, Design.Space.md)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.md)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }

    private var modeHeadline: String {
        switch vm.sessionMode {
        case .interview: return "Ready for your interview"
        case .meeting:   return "Ready for the meeting"
        case .call:      return "Ready for the call"
        case .general:   return "What can I help with?"
        }
    }

    private var modeSubtitle: String {
        switch vm.sessionMode {
        case .interview: return "Hit Start Interview up top, or pick a starter below."
        case .meeting:   return "Record the conversation, or pick a starter below."
        case .call:      return "Record the call, or pick a starter below."
        case .general:   return "Pick a starter or just type below."
        }
    }

    private var starters: [(title: String, subtitle: String, prompt: String)] {
        switch vm.sessionMode {
        case .interview:
            return [
                ("STAR answer",
                 "Walk me through a strong STAR answer",
                 "Walk me through a strong STAR answer for a question about a time I handled a difficult stakeholder."),
                ("Technical gaps",
                 "Suggest topics to brush up before the interview",
                 "Given my background, suggest 5 technical topics I should brush up on before my interview."),
                ("Smart question",
                 "Give me a thoughtful question for the interviewer",
                 "Give me one thoughtful, specific question I can ask the interviewer about the role and team.")
            ]
        case .meeting:
            return [
                ("Summarise so far",
                 "Bullet summary of the last chunk",
                 "Summarise the last 10 minutes of the meeting in concise bullets."),
                ("Action items",
                 "Extract owners and deadlines",
                 "Extract the action items, owners, and deadlines from the meeting so far."),
                ("Decisions",
                 "What was decided?",
                 "List the decisions that have been made in this meeting.")
            ]
        case .call:
            return [
                ("Summarise the call",
                 "What was covered?",
                 "Summarise what we've covered in this call so far in 5 bullets."),
                ("Follow-up email",
                 "Draft a clean recap",
                 "Draft a follow-up email summarising this call and listing any next steps."),
                ("Commitments",
                 "What did I commit to?",
                 "List anything I committed to during this call.")
            ]
        case .general:
            return [
                ("Explain",
                 "Break something down in plain terms",
                 "Explain the following in simple terms so a beginner can follow:\n\n"),
                ("Draft",
                 "Help me write a message",
                 "Help me draft a concise, professional message about:\n\n"),
                ("Next step",
                 "What should I do next?",
                 "Given the context above, what should I focus on next and why?")
            ]
        }
    }

    // MARK: - Conversation

    private func conversationView(session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.md) {
                    ForEach(session.turns) { turn in
                        TurnBubble(turn: turn,
                                   canRetry: turn.id == session.turns.last?.id
                                             && vm.canRetryLastResponse,
                                   onRetry: { vm.retryLastResponse() })
                            .id(turn.id)
                    }
                }
                .padding(.horizontal, Design.Space.lg)
                .padding(.vertical, Design.Space.lg)
            }
            .onChange(of: session.turns.count) { _, _ in
                if let last = session.turns.last?.id {
                    withAnimation(Design.Motion.standard) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.turns.last?.content.count) { _, _ in
                if let last = session.turns.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Turn bubble

private struct TurnBubble: View {
    let turn: ChatTurn
    var canRetry: Bool = false
    var onRetry: () -> Void = {}
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user {
                Spacer(minLength: 48)
                userContent
            } else {
                assistantContent
                Spacer(minLength: 24)
            }
        }
        .onHover { hovering = $0 }
    }

    /// User: compact pill-shaped bubble, accent-tinted, right-aligned.
    private var userContent: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(turn.content)
                .font(Design.Font.body)
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                )

            HStack(spacing: 4) {
                if hovering {
                    Button { copy() } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
                Text(relativeTime)
                    .font(Design.Font.micro.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 12)
        }
    }

    /// Assistant: no avatar, no bubble. An eyebrow label sits above the
    /// markdown text — looks like a doc/spec entry rather than a chat reply.
    /// The label reflects the *actual* model that produced this turn (read
    /// from `turn.model`) — switching the model picker won't retroactively
    /// rewrite past replies.
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(modelLabel)
                .font(Design.Font.eyebrow)
                .tracking(0.4)
                .foregroundColor(.secondary.opacity(0.85))

            if turn.content.isEmpty {
                TypingIndicatorView()
                    .padding(.vertical, 4)
            } else {
                MarkdownResponseView(text: turn.content)
            }

            if !turn.content.isEmpty {
                HStack(spacing: 6) {
                    Text(relativeTime)
                        .font(Design.Font.micro.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if hovering {
                        Button { copy() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                Text(copied ? "Copied" : "Copy")
                                    .font(Design.Font.micro)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .offset(x: -4, y: 0)))
                    }
                    if canRetry {
                        Button(action: onRetry) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Retry")
                                    .font(Design.Font.micro)
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 14)
                .animation(Design.Motion.fast, value: hovering)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            // Subtle vertical rail — lights up while streaming.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(turn.content.isEmpty
                      ? Color.accentColor.opacity(0.55)
                      : Color.white.opacity(0.10))
                .frame(width: 2)
                .padding(.vertical, 2)
        }
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: turn.timestamp, relativeTo: Date())
    }

    /// Display name for the model that produced this turn. Resolves the
    /// stamped `turn.model` id against `OverlayViewModel.availableModels`
    /// so users see "GPT-4o" / "Sonnet 4.6" etc. — not a hardcoded
    /// "Claude". Falls back to a generic "Assistant" for legacy turns
    /// loaded from disk before this field was introduced.
    private var modelLabel: String {
        guard let id = turn.model else { return "Assistant" }
        if let match = OverlayViewModel.availableModels.first(where: { $0.id == id }) {
            return match.name
        }
        return id
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.content, forType: .string)
        withAnimation(Design.Motion.fast) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(Design.Motion.fast) { copied = false }
        }
    }
}

