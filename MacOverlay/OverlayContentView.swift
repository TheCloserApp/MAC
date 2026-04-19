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

    @State private var expanded = false

    var body: some View {
        @Bindable var vm = vm
        ZStack {
            if vm.showOnboarding {
                OnboardingView(isPresented: $vm.showOnboarding)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(1)
            } else if expanded {
                expandedShell
                    .transition(.opacity)
            } else {
                collapsedHeader
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity,
               maxHeight: expanded ? .infinity : nil,
               alignment: expanded ? .topLeading : .topLeading)
        .padding(expanded ? Design.Space.sm : 8)
        .animation(.easeInOut(duration: 0.25), value: vm.showOnboarding)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
        .onAppear {
            if !vm.hasCompletedOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { vm.showOnboarding = true }
                }
            }
        }
        // When onboarding finishes, drop the user into the expanded shell on
        // the chat surface — no extra click needed to "get in".
        .onChange(of: vm.showOnboarding) { wasShowing, isShowing in
            if wasShowing && !isShowing {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    expanded = true
                    vm.primarySurface = .chat
                }
            }
        }
    }

    // MARK: - Expanded shell

    /// Floating-glass shell. Sidebar cells, top strip, primary surface, and
    /// input bar are each independent glass cards with visible gaps between
    /// them. No shared container — everything hovers. The right column only
    /// appears once the user picks a sidebar icon; it hides again if they
    /// click the active icon a second time.
    private var expandedShell: some View {
        HStack(alignment: .top, spacing: Design.cardGap) {
            SidebarView(expanded: $expanded)

            if vm.primarySurface != nil {
                VStack(spacing: Design.cardGap) {
                    TopStripView()
                        .glassCard()

                    primarySurface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassCard()

                    InputBarView()
                        .glassCard()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Design.Motion.spring, value: vm.primarySurface != nil)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .resumes:
                ScrollView { ResumePanelView() }
            case .prompts:
                PromptLibraryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .calendar:
                CalendarPanelView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .browser:
                BrowserShellSurface()
            case .none:
                EmptyView()
            }
        }
        .id(vm.primarySurface)
        .transition(.opacity.combined(with: .offset(y: 4)))
        .animation(Design.Motion.standard, value: vm.primarySurface)
    }

    // MARK: - Collapsed state

    @ViewBuilder
    private var collapsedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsedPillView(expanded: $expanded)

            if vm.resumeFileURL != nil || vm.isGeneratingResume
                || vm.resumeScore != nil || vm.isScoringResume {
                ResumeFloatingPillView()
            }

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
