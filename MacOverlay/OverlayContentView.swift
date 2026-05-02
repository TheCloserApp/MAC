import SwiftUI

/// Top-level overlay view. Two states:
///   - collapsed: floating waveform pill + any active-task floating pills
///                (quick-ask, resume). Click the pill → expand directly.
///   - expanded : full glass shell (sidebar of cells + top strip + primary
///                surface + input bar, each its own floating glass card).
/// Onboarding renders inline when active (never via sheet — keeps it protected
/// by the panel's `sharingType = .none`).
struct OverlayView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        AuthGateView {
            authedShell
        }
        // When the user isn't signed in, AuthGateView force-expands the
        // shell so the panel resizes to its full height — let SwiftUI use
        // it. Otherwise (signed in), respect the user's expansion state.
        .frame(maxWidth: .infinity,
               maxHeight: (vm.isShellExpanded || !vm.auth.isSignedIn) ? .infinity : nil,
               alignment: .topLeading)
        .padding(Design.Space.sm)
        .sheet(isPresented: $vm.showPaywall) {
            PaywallSheet()
        }
    }

    /// The original overlay UI, only mounted once the user is signed in
    /// (Apple or guest). Keeping onboarding inside the gate means the
    /// welcome tour only fires after sign-in.
    private var authedShell: some View {
        @Bindable var vm = vm
        return ZStack {
            if vm.showOnboarding {
                OnboardingView(isPresented: $vm.showOnboarding)
                    .zIndex(1)
            } else if vm.isShellExpanded {
                expandedShell
            } else {
                collapsedHeader
            }
        }
        .onAppear {
            if !vm.hasCompletedOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    vm.showOnboarding = true
                }
            }
        }
        .onChange(of: vm.showOnboarding) { wasShowing, isShowing in
            if wasShowing && !isShowing {
                vm.isShellExpanded = true
                vm.primarySurface = .chat
            }
        }
    }

    // MARK: - Expanded shell

    /// Floating-glass shell. Sidebar cells, top strip, primary surface, and
    /// input bar are each independent glass cards with visible gaps between
    /// them. The layout flips based on `pillAnchor` so the sidebar always
    /// sits next to the pill's screen edge and panels flow away from it.
    private var expandedShell: some View {
        VStack(spacing: 0) {
            // Top card swaps between the full chat surface and the slim
            // mini lift-handle. The composer below stays the SAME view
            // identity so it doesn't re-render or lose its state. The
            // swap is instant — only the NSPanel resize animates — so
            // SwiftUI's layout never lags the panel's frame change.
            Group {
                if vm.isShellMinimized {
                    MiniBarView()
                } else {
                    fullTopCard
                }
            }
            .cardSurface(topRadius: 18, bottomRadius: 0)
            .padding(.horizontal, 20)

            InputBarView()
                .cardSurface(topRadius: 18, bottomRadius: 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var fullTopCard: some View {
        VStack(spacing: 0) {
            TopStripView()

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            primarySurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
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

    // MARK: - Collapsed state

    @ViewBuilder
    private var collapsedHeader: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                CollapsedPillView()

                // Score pill — visible during scoring AND once a score lands.
                if vm.isScoringResume {
                    ResumeIndicatorPill(kind: .scoring)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else if let score = vm.resumeScore {
                    ResumeIndicatorPill(kind: .score(score)) {
                        vm.resumeScore = nil
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                // File pill — visible during generation AND once a file lands.
                // Renders independently so a score + file can show together.
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
