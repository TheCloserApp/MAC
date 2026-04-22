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
        ZStack {
            if vm.showOnboarding {
                OnboardingView(isPresented: $vm.showOnboarding)
                    .zIndex(1)
            } else if vm.isShellExpanded {
                expandedShell
            } else {
                collapsedHeader
            }
        }
        .frame(maxWidth: .infinity,
               maxHeight: vm.isShellExpanded ? .infinity : nil,
               alignment: .topLeading)
        .padding(Design.Space.sm)
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
        HStack(alignment: .top, spacing: Design.cardGap) {
            SidebarView()

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
            }
        }
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
            case .settings:
                PreferencesView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .none:
                EmptyView()
            }
        }
        .id(vm.primarySurface)
    }

    // MARK: - Collapsed state

    @ViewBuilder
    private var collapsedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            CollapsedPillView()

            // Drag handle — not a button, so dragging here moves the panel
            // without accidentally opening the overlay.
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.primary.opacity(0.28))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: 36, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .frame(maxWidth: .infinity, alignment: .leading)

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
