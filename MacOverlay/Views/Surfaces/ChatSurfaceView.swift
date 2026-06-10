import SwiftUI
import AppKit
import AVFoundation
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

        // Documents → extract text, attach as a chip. The full extracted
        // text rides along to the AI on send; only the file name shows in
        // the chat bubble (and as a pending chip in the input bar).
        if ResumeImporter.supportedExtensions.contains(ext) {
            do {
                let text = try ResumeImporter.importFile(url: url)
                let name = url.lastPathComponent
                vm.showManualInput = true
                vm.pendingAttachments.append(
                    OverlayViewModel.PendingAttachment(name: name, extractedText: text)
                )
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
                if showsContinueButton(session: session) {
                    // Empty session that's still resumable (a previously-
                    // started interview / call that never got a message).
                    // Replace the starter cards with the continue
                    // affordance — the cards don't apply once a session
                    // has a kind tied to a live flow.
                    resumableEmptyState(session: session)
                } else {
                    emptyState
                }
            } else {
                conversationView(session: session)
            }
        }
    }

    /// Hero header + Continue-session button for empty sessions tagged as
    /// interview / regular-call. Lets the user immediately re-enter the
    /// paused-live state without having to type anything first.
    private func resumableEmptyState(session: ChatSession) -> some View {
        VStack(spacing: Design.Space.lg) {
            heroHeader
            continueSessionRow(session: session)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.lg)
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
                    // Inline timer sits flush against the transcription
                    // text — same line as the words being captured —
                    // instead of in its own row. Stays visible while
                    // paused so the user sees the frozen duration.
                    if vm.isInterviewSession {
                        LiveSessionTimer()
                    }
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
                        Text(vm.transcription.isEmpty
                             ? "Mic still on — keep speaking and it'll transcribe in the background."
                             : "Queued — sends automatically when this answer finishes.")
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(session.turns) { turn in
                        TurnBubble(turn: turn,
                                   canRetry: turn.id == session.turns.last?.id
                                             && vm.canRetryLastResponse,
                                   onRetry: { vm.retryLastResponse() })
                            .id(turn.id)
                    }
                    if showsContinueButton(session: session) {
                        continueSessionRow(session: session)
                    }
                    // Sentinel pinned to the bottom of the stack. Streaming
                    // scroll snaps to this fixed id once per turn instead of
                    // chasing a moving id every chunk — which was the source
                    // of the visible "breaking" jitter.
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .onChange(of: session.turns.count) { _, _ in
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
            // Throttle streaming-scroll to once every ~120ms via a coarse
            // length bucket. Per-character scrollTo runs faster than the
            // layout settles, which is what made the text look like it was
            // tearing during streaming.
            .onChange(of: (session.turns.last?.content.count ?? 0) / 32) { _, _ in
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

    /// Whether to render the inline "Continue session" affordance.
    /// Shows when the session is a resumable kind (interview /
    /// regular-call / legacy normal) and no live session is currently
    /// running — applies to both empty sessions (resumable shell with
    /// no turns yet) and sessions with prior messages.
    private func showsContinueButton(session: ChatSession) -> Bool {
        guard !vm.isInterviewSession else { return false }
        switch session.kind {
        case .interview, .regularCall, .normal: return true
        case .quickAsk:                          return false
        }
    }

    /// "Continue session" affordance pinned after the last assistant
    /// turn. Clicking enters paused-live state — the bar's call
    /// controls (text + model + play + stop) appear so the user can
    /// resume the mic or pick up typing.
    private func continueSessionRow(session: ChatSession) -> some View {
        let label: String = {
            switch session.kind {
            case .interview:                 return "Continue interview"
            case .regularCall, .normal:      return "Continue call"
            case .quickAsk:                  return "Continue"
            }
        }()
        return HStack {
            Spacer()
            Button {
                vm.enterPausedLiveState()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Design.Accent.blue))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Reopen the call controls in the bar — the mic stays off until you hit play.")
            Spacer()
        }
        .padding(.top, 12)
    }
}

// MARK: - Turn bubble

private struct TurnBubble: View {
    let turn: ChatTurn
    var canRetry: Bool = false
    var onRetry: () -> Void = {}
    @State private var copied = false
    @State private var isSpeaking = false
    @State private var feedback: Feedback = .none

    private enum Feedback { case none, up, down }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user {
                Spacer(minLength: 40)
                userContent
            } else {
                assistantContent
                Spacer(minLength: 0)
            }
        }
    }

    /// User message: ChatGPT-style monochrome grey pill, right-aligned.
    /// Attachments render as small file chips above the text. No metadata
    /// row — the bubble stands on its own, matching the reference UI.
    private var userContent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let names = turn.attachments, !names.isEmpty {
                FlowAttachmentRow(names: names, alignment: .trailing)
            }
            if !turn.content.isEmpty {
                Text(turn.content)
                    .font(Design.Font.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }
        }
    }

    /// Assistant: plain markdown text on the surface, with a ChatGPT-style
    /// row of action icons underneath — copy, read-aloud, thumbs up/down,
    /// regenerate. The row is always visible once the reply has content.
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.content.isEmpty {
                TypingIndicatorView()
                    .padding(.vertical, 4)
            } else {
                MarkdownResponseView(text: turn.content)
                actionRow
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            actionButton(copied ? "checkmark" : "square.on.square",
                         help: copied ? "Copied" : "Copy",
                         active: copied) { copy() }
            actionButton(isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2",
                         help: "Read aloud",
                         active: isSpeaking) { toggleSpeak() }
            actionButton(feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                         help: "Good response",
                         active: feedback == .up) {
                feedback = feedback == .up ? .none : .up
            }
            actionButton(feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                         help: "Bad response",
                         active: feedback == .down) {
                feedback = feedback == .down ? .none : .down
            }
            actionButton("arrow.clockwise", help: "Regenerate") { onRetry() }
        }
        .animation(Design.Motion.fast, value: copied)
        .animation(Design.Motion.fast, value: isSpeaking)
        .animation(Design.Motion.fast, value: feedback)
    }

    /// One icon in the assistant action row. Hover brightens; `active`
    /// paints it in the primary tint (e.g. while reading aloud).
    private func actionButton(_ icon: String,
                              help: String,
                              active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(active ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Color.white.opacity(0.06))
        .help(help)
    }

    private func toggleSpeak() {
        if isSpeaking {
            SpeechReader.shared.stop()
            isSpeaking = false
        } else {
            isSpeaking = true
            SpeechReader.shared.speak(turn.content) {
                isSpeaking = false
            }
        }
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

// MARK: - Read-aloud

/// Thin wrapper around `AVSpeechSynthesizer` so any assistant bubble can
/// speak its text. Single shared instance — starting a new utterance stops
/// whatever was playing. The `onFinish` callback lets the calling bubble
/// reset its speaker icon when playback ends or is cancelled.
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = SpeechReader()

    // Synth + callback are only ever touched from the main thread (button
    // taps + AVSpeechSynthesizer's main-queue delegate callbacks), so the
    // non-Sendable synth is safe behind @unchecked Sendable.
    private let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, onFinish: @escaping () -> Void) {
        // Clear the previous callback before cancelling so the incoming
        // utterance's didCancel doesn't fire the new bubble's reset.
        self.onFinish = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        self.onFinish = onFinish
        let utterance = AVSpeechUtterance(string: text)
        synth.speak(utterance)
    }

    func stop() {
        onFinish = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        let cb = onFinish
        onFinish = nil
        cb?()
    }
}

// MARK: - Attachment chip row

/// Compact row of file chips shown above a user message. Each chip just
/// shows the file icon + name — the actual extracted text was sent to the
/// AI as part of the prompt but is intentionally NOT rendered here.
struct FlowAttachmentRow: View {
    let names: [String]
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 6) {
            if alignment == .trailing { Spacer(minLength: 0) }
            ForEach(names, id: \.self) { name in
                HStack(spacing: 5) {
                    Image(systemName: iconFor(name))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            }
            if alignment == .leading { Spacer(minLength: 0) }
        }
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
}

// MARK: - Live session timer (inline)

/// Tiny mm:ss / h:mm:ss counter shown on the live transcript strip while
/// an interview / call session is active. Reads `interviewElapsedSeconds`
/// + the current running phase off the view model so pause/resume keeps
/// the value frozen at its current state instead of restarting from 0.
private struct LiveSessionTimer: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let paused = vm.isInterviewPaused
        return HStack(spacing: 4) {
            Circle()
                .fill(paused ? Color.secondary : Color.red)
                .frame(width: 5, height: 5)
                .opacity(0.9)
            Text(formatted)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((paused ? Color.secondary : Color.red).opacity(0.10))
        .clipShape(Capsule())
        .onReceive(ticker) { d in tick = d }
    }

    private var formatted: String {
        let liveSlice: TimeInterval
        if let started = vm.interviewRunningSince {
            liveSlice = tick.timeIntervalSince(started)
        } else {
            liveSlice = 0
        }
        let secs = Int(vm.interviewElapsedSeconds + liveSlice)
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

