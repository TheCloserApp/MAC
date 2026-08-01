import SwiftUI
import AppKit

/// Top-level overlay view. Two states:
///   - `.pill`     — collapsed brand pill, full ambient state shown via the
///                   pill's color/animation only. Active background work
///                   (resume scoring, quick-ask, etc.) auto-promotes the
///                   shell to `.expanded` so the user always sees status
///                   inside the panel rather than in floating peer pills.
///   - `.expanded` — full glass shell. Layout adapts to `primarySurface`:
///                     · `nil`  → just the input bar (compact composer).
///                     · set    → top card (title + body) + input bar.
/// Onboarding renders inline when active.
struct OverlayView: View {
    @Environment(OverlayViewModel.self) private var vm

    /// Chrome (session title row, input bar) reveals on hover and melts
    /// away otherwise — matching the reference UI where only the content
    /// is visible until the cursor enters the panel.
    @State private var chromeHovering = false

    /// The input bar is the whole UI in pill stage, so it never hides
    /// there. While expanded it shows on hover — and stays while the user
    /// has a draft typed or is interacting, so it can't vanish mid-thought.
    private var barVisible: Bool {
        vm.shellStage == .pill
            || chromeHovering
            || !vm.manualInput.isEmpty
    }

    var body: some View {
        @Bindable var vm = vm
        rootContent
            .frame(maxWidth: .infinity,
                   maxHeight: .infinity,
                   alignment: .topLeading)
            .padding(Design.Space.sm)
            .preferredColorScheme(.dark)
            .tint(Design.Accent.chatGPT)
            .foregroundStyle(Design.Ink.primary)
            .onChange(of: vm.showOnboarding) { wasShowing, isShowing in
                if wasShowing && !isShowing {
                    // Land the just-onboarded user on a bar-only expanded
                    // shell — the chat surface is empty so opening the
                    // body would feel hollow. Surface stays nil; user
                    // promotes to a real surface by clicking a button.
                    vm.shellStage = .expanded
                    vm.primarySurface = nil
                }
            }
            // Fire the panel-resize callback whenever the pill popup
            // appears or disappears so AppDelegate can grow / shrink the
            // host window to fit the floating result card.
            .onChange(of: vm.hasPillPopup) { _, active in
                vm.onPillPopupChange?(active)
            }
    }

    /// Aggregate flag: any background activity that has its own status
    /// surface inside the expanded shell. Used to decide when to render
    /// the pill-anchored floating popup.
    private var hasAmbientWork: Bool {
        vm.isScoringResume || vm.isGeneratingResume || vm.resumeScore != nil
            || vm.resumeFileURL != nil || vm.isQuickAskSending
            || !vm.quickAskResponse.isEmpty
    }

    private var isShowingOnboarding: Bool {
        vm.showOnboarding || !vm.hasCompletedOnboarding
    }

    @ViewBuilder
    private var rootContent: some View {
        @Bindable var vm = vm
        if isShowingOnboarding {
            OnboardingView(isPresented: $vm.showOnboarding)
        } else {
            stageStack
        }
    }

    // MARK: - Stage rendering

    @ViewBuilder
    private var stageStack: some View {
        ZStack(alignment: .bottom) {
            upperLayer
            InputBarView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.panelInsetLeading)
                .padding(.trailing, Self.panelInsetTrailing)
                // The bar's job is to sit exactly at the bottom of the
                // panel and never move. Explicitly nil out the animation
                // for the two state values that produced the visible
                // jump — primarySurface and shellStage — so any
                // withAnimation block on a surface-button click cannot
                // lerp the bar's layout. The bar still animates its
                // own internal hover/press states normally.
                .animation(nil, value: vm.primarySurface)
                .animation(nil, value: vm.shellStage)
                // Hover-reveal: opacity (not removal) so the layout never
                // reflows and the panel height stays put.
                .opacity(barVisible ? 1 : 0)
                .allowsHitTesting(barVisible)
                .animation(.easeInOut(duration: 0.18), value: barVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onHover { chromeHovering = $0 }
        // Floating popup that hovers above the brand pill when the shell
        // is collapsed. Resume score / generated-resume / quick-ask
        // results render here so the user never loses status just
        // because they haven't manually expanded the bar.
        .overlay(alignment: .bottomLeading) {
            if vm.shellStage == .pill && hasAmbientStatus {
                pillFloatingPopup
                    .padding(.leading, Self.panelInsetLeading + 4)
                    .padding(.bottom, 60)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // Drag grip on the trailing edge — lets the user widen / narrow the
        // panel on screen. Only shown with a surface open (where extra room
        // matters and the shell is committed-open, so it can't auto-collapse
        // mid-drag). Revealed on hover like the rest of the chrome; kept
        // hit-testable even when faded so an in-flight drag is never dropped
        // if the cursor briefly leaves the panel bounds.
        // Corner drag-resize — the single resize affordance (the old
        // trailing-edge grip was redundant once the corner could do both
        // axes). Bottom-trailing, width AND height together with the top
        // edge pinned; hover-revealed like the rest of the chrome.
        .overlay(alignment: .bottomTrailing) {
            if vm.shellStage == .expanded && vm.primarySurface != nil {
                CornerResizeGrip { dx, dy, ended in
                    vm.onCornerResize?(dx, dy, ended)
                }
                .opacity(chromeHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: chromeHovering)
            }
        }
        .animation(Design.Motion.standard, value: vm.shellStage)
        .animation(Design.Motion.standard, value: vm.isScoringResume)
        .animation(Design.Motion.standard, value: vm.isGeneratingResume)
        .animation(Design.Motion.standard, value: vm.resumeScore)
        .animation(Design.Motion.standard, value: vm.resumeFileURL)
        .animation(Design.Motion.standard, value: vm.isQuickAskSending)
        .animation(Design.Motion.standard, value: vm.quickAskResponse.isEmpty)
    }

    /// Pill-anchored floating popup. Renders the same indicator pills as
    /// the expanded-shell ambient strip, plus the Quick Ask result panel,
    /// so the user can dispatch a hotkey while collapsed and see the
    /// result without having to open anything.
    @ViewBuilder
    private var pillFloatingPopup: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if vm.isScoringResume {
                    ResumeIndicatorPill(kind: .scoring)
                } else if let score = vm.resumeScore {
                    ResumeIndicatorPill(kind: .score(score)) {
                        vm.resumeScore = nil
                    }
                }

                if vm.isGeneratingResume {
                    ResumeIndicatorPill(kind: .generating(vm.resumeGenerationStatus))
                } else if let url = vm.resumeFileURL {
                    ResumeIndicatorPill(kind: .file(url)) {
                        vm.resumeFileURL = nil
                    }
                }
            }

            if vm.isQuickAskSending || !vm.quickAskResponse.isEmpty {
                QuickAskPillView()
            }
        }
    }

    /// Reserve enough vertical space at the bottom of `upperLayer` for
    /// the bar (44pt brand button + 4pt vertical padding × 2 = 52pt) plus
    /// an 8pt gap so the top card never visually crowds the bar.
    private static let barReservedSpace: CGFloat = 60

    /// Everything that sits above the bar — the top card when a surface
    /// is open, the ambient status strip otherwise. Animations for the
    /// surface transition live here (not on the parent ZStack) so the
    /// sibling InputBarView never inherits them.
    /// Live Focus hugs its content: the glass card only covers the Q&A,
    /// and the panel space below it is empty SwiftUI — which the hosting
    /// view doesn't claim, so clicks pass through to the window beneath.
    /// Applies on BOTH the interview and chat surfaces — they render the
    /// same live session, and requiring `.interview` here left the chat
    /// surface's focus view floating centered in a full-height card.
    private var focusHugging: Bool { vm.focusHuggingActive }

    @ViewBuilder
    private var upperLayer: some View {
        VStack(spacing: 0) {
            if vm.shellStage == .expanded && vm.primarySurface != nil {
                if focusHugging {
                    // Live Focus: the session-name header is a separate bar
                    // that reveals on hover ABOVE the card. It reserves its
                    // own slot (transparent when idle, so no empty bar
                    // shows) so the card — transcript strip + answer — never
                    // moves, and the header never overlaps the transcript.
                    // The stack's natural height is measured and reported so
                    // AppDelegate can track the panel height to the content
                    // in realtime — the window grows/shrinks smoothly with
                    // the answer instead of clipping it or leaving a dead
                    // gap below the card.
                    VStack(spacing: 0) {
                        revealOnHover(floatingHeaderBar)
                            .padding(.bottom, 6)
                        topCard
                            .cardSurface(topRadius: 16, bottomRadius: 16, opacity: vm.backgroundOpacity)
                            .transition(.opacity)
                    }
                    .padding(.leading, Self.panelInsetLeading)
                    .padding(.trailing, Self.panelInsetTrailing)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FocusShellHeightKey.self,
                                               value: g.size.height)
                    })
                    .onPreferenceChange(FocusShellHeightKey.self) { h in
                        guard h > 0 else { return }
                        vm.onFocusContentHeight?(h)
                    }
                    Spacer(minLength: 0)
                } else {
                    topCard
                        .cardSurface(topRadius: 16, bottomRadius: 16, opacity: vm.backgroundOpacity)
                        .padding(.leading, Self.panelInsetLeading)
                        .padding(.trailing, Self.panelInsetTrailing)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                }
            } else if vm.shellStage == .expanded && vm.primarySurface == nil
                        && hasAmbientStatus {
                Spacer(minLength: 0)
                ambientStatusStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Self.barReservedSpace)
        .animation(.easeInOut(duration: 0.18), value: vm.primarySurface)
        .animation(.easeInOut(duration: 0.18), value: vm.shellStage)
    }

    /// Shared horizontal insets for the floating top card AND the bar.
    /// Symmetric — the card fills the (now 400pt-wide) panel edge to
    /// edge like the ChatGPT companion window, instead of the old
    /// shifted-left layout with a wide empty right margin.
    private static let panelInsetLeading: CGFloat = 8
    private static let panelInsetTrailing: CGFloat = 8

    /// Top card content — title + body. `.headed` (title-only) state is
    /// gone; if the user opens a surface, they see its body.
    /// Hover-reveal chrome content: editable session title, close,
    /// compose, ⋯. Opacity / hit-testing are applied by `revealOnHover`
    /// so the optional opaque backing fades together with the title.
    private var titleStripContent: some View {
        VStack(spacing: 0) {
            TopStripView()
            Rectangle()
                .fill(Design.Surface.separator)
                .frame(height: 0.5)
        }
    }

    /// Fade `view` in only while the cursor is over the panel.
    private func revealOnHover(_ view: some View) -> some View {
        view
            .opacity(chromeHovering ? 1 : 0)
            .allowsHitTesting(chromeHovering)
            .animation(.easeInOut(duration: 0.18), value: chromeHovering)
    }

    /// Live Focus session-name header — a STANDALONE bar that floats above
    /// the answer card (placed by `upperLayer`). Same glass surface as the
    /// card so the two read as one stack, but kept separate so revealing it
    /// on hover never overlaps the live-transcript strip at the card's top
    /// nor shifts the answer.
    private var floatingHeaderBar: some View {
        TopStripView()
            .cardSurface(topRadius: 16, bottomRadius: 16, opacity: vm.backgroundOpacity)
    }

    @ViewBuilder
    private var topCard: some View {
        if focusHugging {
            // Live Focus: card body only. The session-name header lives in
            // its own floating bar above the card (see upperLayer), so the
            // card top is free for the transcript strip + answer.
            primarySurface
                .frame(maxWidth: .infinity, alignment: .top)
        } else {
            VStack(spacing: 0) {
                // Other surfaces keep the chrome IN the layout (opacity-
                // only reveal) so the scrolled body never reflows as the
                // cursor enters.
                revealOnHover(titleStripContent)
                primarySurface
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .top)
            }
        }
    }

    // MARK: - Ambient status

    private var hasAmbientStatus: Bool {
        vm.isScoringResume || vm.resumeScore != nil
            || vm.isGeneratingResume || vm.resumeFileURL != nil
            || vm.isQuickAskSending || !vm.quickAskResponse.isEmpty
    }

    /// In-shell replacement for the floating quick-ask + resume indicator
    /// pills that used to hover above the collapsed brand pill. Shown
    /// directly above the input bar when the user has no surface open.
    @ViewBuilder
    private var ambientStatusStrip: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if vm.isScoringResume {
                    ResumeIndicatorPill(kind: .scoring)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else if let score = vm.resumeScore {
                    ResumeIndicatorPill(kind: .score(score)) {
                        vm.resumeScore = nil
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                if vm.isGeneratingResume {
                    ResumeIndicatorPill(kind: .generating(vm.resumeGenerationStatus))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else if let url = vm.resumeFileURL {
                    ResumeIndicatorPill(kind: .file(url)) {
                        vm.resumeFileURL = nil
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(Design.Motion.standard, value: vm.isScoringResume)
            .animation(Design.Motion.standard, value: vm.isGeneratingResume)
            .animation(Design.Motion.standard, value: vm.resumeScore)
            .animation(Design.Motion.standard, value: vm.resumeFileURL)

            if vm.isQuickAskSending || !vm.quickAskResponse.isEmpty {
                QuickAskPillView()
            }
        }
        .padding(.leading, Self.panelInsetLeading)
        .padding(.trailing, Self.panelInsetTrailing)
    }

    // MARK: - Primary surface dispatch

    @ViewBuilder
    private var primarySurface: some View {
        Group {
            switch vm.primarySurface {
            case .chat:
                ChatSurfaceView()
            case .interview:
                InterviewSurfaceView()
            case .sessions:
                HistoryPanelView()
            case .resumes:
                ScrollView { ResumePanelView() }
                    .hiddenScrollGutter()
            case .prompts:
                PromptLibraryView()
            case .calendar:
                CalendarPanelView()
            case .browser:
                BrowserShellSurface()
            case .settings:
                PreferencesView()
            case .none:
                EmptyView()
            }
        }
        // `alignment: .top` matters: the default (.center) floated any
        // body shorter than the card — the Live Focus Q&A — in the
        // vertical middle of the panel. And in focus mode the height must
        // HUG the content (`nil`), not claim .infinity, or the greedy
        // frame defeats `focusHugging` and the card covers the full panel.
        .frame(maxWidth: .infinity,
               maxHeight: focusHugging ? nil : .infinity,
               alignment: .top)
        .id(vm.primarySurface)
    }
}

// MARK: - Resize grip

/// Reports the Live Focus stack's natural height so AppDelegate can track
/// the panel height to the content in realtime.
private struct FocusShellHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Diagonal corner grip at the panel's bottom-trailing. Reports cumulative
/// drag translation in both axes so AppDelegate can resize the host panel's
/// width and height together.
private struct CornerResizeGrip: View {
    /// `(cumulative dx, cumulative dy, isEnded)`, dy positive = downward.
    let onResize: (CGFloat, CGFloat, Bool) -> Void
    @State private var hovering = false
    /// Screen-space anchor captured on the first drag event. See the
    /// gesture below for why SwiftUI's own translation can't be used.
    @State private var dragAnchor: NSPoint?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(Design.Ink.tertiary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Design.Surface.controlHoverFill
                                   : Design.Surface.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { Self.diagonalCursor.push() } else { NSCursor.pop() }
            }
            // Screen-space deltas, NOT SwiftUI's translation. The grip
            // lives INSIDE the window it resizes, so any window-relative
            // coordinate space (.global is window-relative on macOS) moves
            // under the cursor as the panel grows — each event then reports
            // a translation polluted by the resize it just caused, which is
            // exactly the feedback loop that made dragging flicker.
            // `NSEvent.mouseLocation` is absolute screen space and cannot
            // feed back. Screen y grows upward, so invert it to keep
            // "drag down = taller".
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let loc = NSEvent.mouseLocation
                        let anchor = dragAnchor ?? loc
                        if dragAnchor == nil { dragAnchor = loc }
                        onResize(loc.x - anchor.x, anchor.y - loc.y, false)
                    }
                    .onEnded { _ in
                        let loc = NSEvent.mouseLocation
                        let anchor = dragAnchor ?? loc
                        onResize(loc.x - anchor.x, anchor.y - loc.y, true)
                        dragAnchor = nil
                    }
            )
            .help("Drag to resize")
            .padding(.trailing, 2)
            .padding(.bottom, 2)
    }

    /// Real diagonal resize cursor on macOS 15+, crosshair fallback below
    /// (AppKit exposes no public diagonal cursor before then).
    private static var diagonalCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: .bottomRight, directions: .all)
        }
        return .crosshair
    }
}

// MARK: - Browser shell

/// When the browser surface is active, ensure a tab exists and show the
/// existing BrowserPanelView inside the shell.
private struct BrowserShellSurface: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var customURL: String = ""

    var body: some View {
        Group {
            if vm.browserTabs.isEmpty {
                emptyState
            } else {
                BrowserPanelView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Design.Ink.tertiary)
                Text("No tabs open")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                Text("Pick a quick start, or type a custom URL to open it in a new tab.")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 8) {
                quickStartChip(title: "Google",  icon: "magnifyingglass",
                               url: "https://www.google.com")
                quickStartChip(title: "ChatGPT", icon: "bubble.left.and.text.bubble.right",
                               url: "https://chat.openai.com")
                quickStartChip(title: "Claude",  icon: "sparkles",
                               url: "https://claude.ai")
            }

            customURLField
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var customURLField: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
            TextField("Enter a URL (e.g. example.com)", text: $customURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Design.Ink.primary)
                .onSubmit { openCustomURL() }
            Button { openCustomURL() } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Design.Ink.muted : Design.Accent.chatGPT)
            }
            .buttonStyle(.plain)
            .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Open URL")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Design.Surface.inputFill))
        .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
        .frame(maxWidth: 340)
    }

    private func openCustomURL() {
        var raw = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "https://" + raw }
        if let url = URL(string: raw) {
            vm.addTab(url: url)
            customURL = ""
        }
    }

    /// Capsule chip used in the empty state — same chip style the
    /// Interview / Resume cards use, so the four quick-start destinations
    /// (Google, ChatGPT, Claude) read as a consistent set.
    private func quickStartChip(title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                vm.addTab(url: u)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Design.Ink.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
    }
}
