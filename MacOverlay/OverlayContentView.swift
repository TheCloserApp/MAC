import SwiftUI

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
            .sheet(isPresented: $vm.showPaywall) {
                PaywallSheet()
            }
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
            .onChange(of: vm.auth.isSignedIn) { wasSignedIn, isSignedIn in
                if !wasSignedIn && isSignedIn {
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
        vm.showOnboarding || !vm.auth.isSignedIn
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
    private var focusHugging: Bool {
        (vm.primarySurface == .interview || vm.primarySurface == .chat)
            && vm.isInterviewSession
            && !vm.isInterviewTextOnly && vm.interviewFocusMode
    }

    @ViewBuilder
    private var upperLayer: some View {
        VStack(spacing: 0) {
            if vm.shellStage == .expanded && vm.primarySurface != nil {
                topCard
                    .cardSurface(topRadius: 16, bottomRadius: 16, opacity: vm.backgroundOpacity)
                    .padding(.leading, Self.panelInsetLeading)
                    .padding(.trailing, Self.panelInsetTrailing)
                    .frame(maxHeight: focusHugging ? nil : .infinity)
                    .transition(.opacity)
                if focusHugging {
                    Spacer(minLength: 0)
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
    @ViewBuilder
    private var topCard: some View {
        VStack(spacing: 0) {
            // Title + compose + ⋯ + ✕ reveal on hover; opacity keeps the
            // row's space so the surface body never jumps.
            VStack(spacing: 0) {
                TopStripView()
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
            }
            .opacity(chromeHovering ? 1 : 0)
            .allowsHitTesting(chromeHovering)
            .animation(.easeInOut(duration: 0.18), value: chromeHovering)
            primarySurface
                // alignment: .top — when the body is shorter than the
                // card (focus mode, short answers) it pins to the top
                // instead of centering vertically.
                .frame(maxWidth: .infinity,
                       maxHeight: focusHugging ? nil : .infinity,
                       alignment: .top)
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
                    .foregroundStyle(.tertiary)
                Text("No tabs open")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Pick a quick start, or type a custom URL to open it in a new tab.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
            TextField("Enter a URL (e.g. example.com)", text: $customURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .onSubmit { openCustomURL() }
            Button { openCustomURL() } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? .secondary.opacity(0.4) : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Open URL")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
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
            .foregroundColor(.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
    }
}
