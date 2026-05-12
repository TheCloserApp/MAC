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
            // Background work (resume scoring/generation, quick-ask) used
            // to render as floating peer pills above the brand. They now
            // live inside the expanded shell — so any of them firing while
            // collapsed promotes the shell. The user never has to hunt for
            // status in two places.
            .onChange(of: hasAmbientWork) { _, busy in
                if busy && vm.shellStage == .pill {
                    withAnimation(Design.Motion.spring) {
                        vm.shellStage = .expanded
                    }
                }
            }
    }

    /// Aggregate flag: any background activity that has its own status
    /// surface inside the expanded shell. Used to auto-promote out of
    /// pill state so the user sees what's happening.
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
        VStack(alignment: .center, spacing: 0) {
            // Top card appears only when a primary surface is selected.
            // No surface = "compact" expanded shell (just the bar). This
            // replaces the old `.composer` / `.headed` distinction.
            if vm.shellStage == .expanded && vm.primarySurface != nil {
                HStack(spacing: 0) {
                    Spacer(minLength: Self.topCardLeftInset)
                    topCard
                        .cardSurface(topRadius: 18, bottomRadius: 0)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: Self.topCardRightInset)
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Ambient status strip — quick-ask response + resume work.
            // Only shown in `.expanded` and only when a surface ISN'T
            // already open (so the surface body owns its own real estate).
            if vm.shellStage == .expanded && vm.primarySurface == nil
                && hasAmbientStatus {
                ambientStatusStrip
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // The bar — same view in every stage; always full width.
            InputBarView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Design.Motion.expand, value: vm.shellStage)
        .animation(Design.Motion.expand, value: vm.primarySurface)
    }

    /// Asymmetric horizontal insets for the top card. The brand pill on
    /// the bar's left edge eats ~52pt; symmetric padding makes the card
    /// look offset. The extra leading inset pulls the card's visual
    /// center to the post-brand area, where the user's eye expects it.
    private static let topCardLeftInset: CGFloat = 60
    private static let topCardRightInset: CGFloat = 24

    /// Top card content — title + body. `.headed` (title-only) state is
    /// gone; if the user opens a surface, they see its body.
    @ViewBuilder
    private var topCard: some View {
        VStack(spacing: 0) {
            TopStripView()
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
            primarySurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(.horizontal, Self.topCardLeftInset)
    }

    // MARK: - Primary surface dispatch

    @ViewBuilder
    private var primarySurface: some View {
        Group {
            switch vm.primarySurface {
            case .chat:
                ChatSurfaceView()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(vm.primarySurface)
    }
}

// MARK: - Browser shell

/// When the browser surface is active, ensure a tab exists and show the
/// existing BrowserPanelView inside the shell.
private struct BrowserShellSurface: View {
    @Environment(OverlayViewModel.self) private var vm

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
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No tabs open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Button("Open Google") { vm.addTab() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
