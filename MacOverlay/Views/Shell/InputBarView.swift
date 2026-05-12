import SwiftUI
import AppKit

/// ChatGPT-desktop-style composer. Layout:
///   ┌──────────────────────────────────────────────────┐
///   │ [multi-line text area]                           │
///   │                                                  │
///   │ [+]  [mode ▼]              [model ▼]  [🎤]  [↑]  │
///   └──────────────────────────────────────────────────┘
/// Plus button captures a screenshot, mode menu picks the session mode /
/// custom prompt, model menu picks the LLM, mic toggles recording (or
/// stops streaming), send fires the message.
struct InputBarView: View {
    @Environment(OverlayViewModel.self) private var vm
    @FocusState private var inputFocused: Bool

    /// Tracks whether the user has actively engaged with the expanded
    /// shell (clicked a button, focused the text field, opened a
    /// surface). When `false` and the mouse leaves the bar, the shell
    /// auto-collapses back to `.pill` — "hover to preview, click to
    /// commit". When `true`, the shell stays open until the user
    /// explicitly collapses it.
    @State private var engaged = false
    /// Pending auto-collapse task. Cancelled if the mouse re-enters or
    /// the user engages before it fires.
    @State private var autoCollapseTask: Task<Void, Never>?
    /// Pending focus-grab task. Stored so a rapid stage flip cancels the
    /// previous focus attempt — otherwise repeated expand/collapse cycles
    /// queue up multiple delayed focus grabs that fire after the user has
    /// moved on.
    @State private var focusTask: Task<Void, Never>?
    /// Logo hover state — drives the subtle scale/brightness lift so the
    /// brand button visibly responds the instant the cursor lands on it,
    /// even before the dwell-debounced expansion fires.
    @State private var brandHovered = false
    /// Pending hover-to-expand task. A short dwell (`brandHoverDwell`)
    /// debounces the expansion so a quick mouse-cross doesn't pop the
    /// bar open. Cancelled if the cursor leaves before it elapses.
    @State private var brandHoverTask: Task<Void, Never>?

    /// Mouse must rest on the brand logo this long before the bar
    /// expands. Short enough to feel instant on intent, long enough that
    /// sweeping past on the way to something else doesn't fire it.
    private let brandHoverDwell: Duration = .milliseconds(140)

    var body: some View {
        @Bindable var vm = vm
        // Single-row layout: brand logo always present on the left; in
        // `.pill` we render only the logo. In any other stage the rest of
        // the bar (buttons + text field + send) appears INLINE next to it
        // so the brand logo never leaves its position — the capsule just
        // grows wider to accommodate.
        VStack(alignment: .leading, spacing: 6) {
            if vm.pendingScreenshot != nil && vm.shellStage != .pill {
                screenshotChip
            }
            barRow
        }
        // Constant horizontal padding across stages — animating padding
        // 4 → 8 during expansion shifts the brand pill 4pt right mid-flight,
        // which reads as the icon "twitching" as the bar grows. Lock it.
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(barShape.fill(Design.Surface.shellFill))
        .overlay(barShape.stroke(Color.white.opacity(0.10), lineWidth: 0.75))
        // Clip transitioning content (inner HStack sliding in from the
        // leading edge) to the capsule outline so the controls visibly
        // emerge from inside the bar instead of bleeding past it.
        .clipShape(barShape)
        .designShadow(Design.Shadow.raised)
        .animation(Design.Motion.expand, value: vm.shellStage)
        // Hover-preview tracking: when the bar expanded purely from a
        // hover (no click yet), watch for the mouse leaving the panel.
        // If it leaves and the user hasn't actually clicked anything,
        // schedule a collapse back to `.pill` after a short dwell.
        // Re-entering cancels. Applies to every non-pill stage so that
        // a hover-induced expansion never gets stranded open just
        // because some unrelated state transition flipped the stage.
        .onHover { hovering in
            if hovering {
                autoCollapseTask?.cancel()
                autoCollapseTask = nil
            } else if vm.shellStage != .pill && !engaged {
                scheduleAutoCollapse()
            }
        }
        // Tap anywhere inside the bar (not on a button) is enough to
        // engage. simultaneousGesture so it doesn't swallow button taps.
        .simultaneousGesture(
            TapGesture().onEnded { engaged = true }
        )
        .onChange(of: vm.manualInput) { _, _ in
            // User typed something — clearly engaged.
            if !vm.manualInput.isEmpty { engage() }
        }
        .onChange(of: vm.shellStage) { _, newStage in
            // Cancel any in-flight focus grab — a new stage transition
            // supersedes the previous one.
            focusTask?.cancel()
            focusTask = nil
            // Auto-focus the text field once the bar expands beyond the
            // pill — but only if the user actually engaged (clicked).
            // Otherwise a pure hover would auto-focus the field and feel
            // like the bar is grabbing focus on every mouse-cross.
            if newStage != .pill && engaged {
                focusTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    inputFocused = true
                }
            }
            // Returning to .pill resets the engagement flag for next preview.
            if newStage == .pill {
                engaged = false
                autoCollapseTask?.cancel()
                autoCollapseTask = nil
            }
        }
    }

    /// Mark the user as actively engaged with the open bar. Cancels any
    /// pending auto-collapse so a "hover ended" signal that arrived just
    /// before the click doesn't fire after the user has clearly committed.
    private func engage() {
        engaged = true
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
    }

    /// Schedule a collapse back to `.pill` after a short dwell. If the
    /// user re-enters or engages before the dwell elapses, the task is
    /// cancelled and the bar stays open.
    private func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  vm.shellStage != .pill,
                  !engaged else { return }
            withAnimation(Design.Motion.spring) {
                vm.shellStage = .pill
            }
        }
    }

    /// One horizontal row, ordered: brand · text-input · + · history · mode
    /// · resume · settings · model · mic · send. Each non-brand button is
    /// gated by `BarCustomization` so users can hide ones they don't use
    /// via Preferences → Panel.
    ///
    /// The text input is the flexible element — it expands to fill any
    /// extra horizontal space the user gives the panel by dragging it
    /// wider. Everything else stays at its natural width.
    @ViewBuilder
    private var barRow: some View {
        @Bindable var vm = vm
        let bar = vm.barCustomization
        // `alignment: .center` + a fixed minimum row height keeps the
        // brand pill at exactly the same Y across every stage. Without
        // this, the row's intrinsic height fluctuates as buttons / the
        // text field appear-disappear, and the brand visibly drifts up
        // or down during the stage animation.
        // The brand is rendered as a leading-anchored OVERLAY rather than
        // as the first HStack child. Reason: even with `.transition(.opacity)`
        // on the controls and a unified animation curve, SwiftUI re-runs the
        // HStack's layout pass during the stage transition. Anything that
        // shifts in that pass (the inserted sibling's intrinsic sizing, the
        // spacing slot growing from 0→4, the row's measured min-height
        // settling) drags the brand a pixel or two with it — that's the
        // wobble. Lifting the brand out of the flow into an overlay anchored
        // to .leading makes its position purely a function of the bar
        // capsule's leading edge, which never moves. The HStack just grows
        // wider to the right behind it.
        HStack(alignment: .center, spacing: 4) {
            // Reserve the slot the brand used to occupy so the controls
            // start at the same X they did before. Same width as the
            // brand button's frame (44pt) so nothing else in the row
            // shifts when this refactor lands.
            Color.clear
                .frame(width: 44, height: 44)

            if vm.shellStage != .pill {
                // Plain opacity transition — no transform, so the
                // controls just fade in inside the capsule as it grows.
                HStack(alignment: .center, spacing: 4) {
                    divider
                    if bar.showTextField {
                        textInputField
                    }
                    if bar.showNewSession {
                        newSessionButton
                    }
                    if bar.showHistory && FeatureFlags.sessionsHistoryEnabled {
                        historyButton
                    }
                    if bar.showMode {
                        permissionsMenu
                    }
                    surfaceButtons
                    if FeatureFlags.workspacesEnabled {
                        workspaceButton
                    }
                    if bar.showModel {
                        modelMenu
                    }
                    if bar.showMic {
                        micButton
                    }
                    if bar.showSend {
                        sendButton
                    }
                }
                .clipped()
                .transition(.opacity)
            }
        }
        // Lock the row height to the brand-button height — the brand is
        // the tallest stable element in every stage. Pinning it here
        // means the row never gets shorter when only the brand is shown
        // (`.pill`) or taller when an unrelated control happens to draw
        // a few extra pixels.
        .frame(minHeight: 44)
        // Brand pinned to the leading edge, outside the HStack flow. Its
        // X is fixed regardless of what the row does mid-animation.
        .overlay(alignment: .leading) {
            brandLogoButton
        }
    }

    /// The "ask anything" field. Sits right after the brand pill so it's
    /// the first thing the user's eye lands on — primary affordance for
    /// just typing a prompt without navigating any surface.
    private var textInputField: some View {
        @Bindable var vm = vm
        return TextField("Ask anything", text: $vm.manualInput, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(vm.barCustomization.fontSize)))
            .foregroundColor(.primary)
            .lineLimit(1...3)
            .focused($inputFocused)
            .onSubmit { send() }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 140, maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )
    }

    /// Bar background shape. Always a full Capsule — the bar reads as
    /// its own floating glass element in every stage. The narrower top
    /// card in expanded-with-surface floats slightly above it.
    private var barShape: Capsule {
        Capsule(style: .continuous)
    }

    /// Vertical hairline that visually separates the brand pill from the
    /// rest of the row when the bar is expanded.
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, 4)
    }

    /// Brand logo lives at the leading edge in every stage, so SwiftUI
    /// keeps the same view identity across stage changes — no re-render,
    /// no jump. Click toggles between `.pill` and `.expanded`. Hovering
    /// while collapsed expands to a bar-only `.expanded` (no surface).
    private var brandLogoButton: some View {
        Button {
            cancelBrandHoverDwell()
            withAnimation(Design.Motion.expand) {
                if vm.shellStage == .pill {
                    vm.shellStage = .expanded
                } else {
                    vm.shellStage = .pill
                }
            }
        } label: {
            WaveformLogo()
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                // No scaleEffect on hover — center-anchored scaling makes
                // the brand visibly grow in both directions, which reads as
                // the icon "shifting right then snapping back" once the
                // hover state ends. Bar expansion + the brightness lift
                // below are enough hover feedback on their own.
                .brightness(brandHovered ? 0.04 : 0)
                .animation(.easeOut(duration: 0.14), value: brandHovered)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            brandHovered = isHovering
            if isHovering, vm.shellStage == .pill {
                scheduleBrandHoverExpand()
            } else {
                cancelBrandHoverDwell()
            }
        }
        .help(vm.shellStage == .pill ? "Hover or click to open" : "Click to collapse")
    }

    private func scheduleBrandHoverExpand() {
        cancelBrandHoverDwell()
        brandHoverTask = Task { @MainActor in
            try? await Task.sleep(for: brandHoverDwell)
            guard !Task.isCancelled, vm.shellStage == .pill else { return }
            withAnimation(Design.Motion.expand) {
                vm.shellStage = .expanded
            }
        }
    }

    private func cancelBrandHoverDwell() {
        brandHoverTask?.cancel()
        brandHoverTask = nil
    }

    // MARK: - Left utilities

    private var newSessionButton: some View {
        Button {
            vm.startNewSession()
            withAnimation(Design.Motion.spring) {
                vm.primarySurface = .chat
                if vm.shellStage == .pill { vm.shellStage = .expanded }
            }
        } label: {
            iconCircle(systemName: "plus", tint: .secondary, weight: .semibold)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help("New session (⌘N)")
    }

    /// History button — sits immediately next to "+" so the two are read
    /// as a related pair. Brings up History; preserves the current panel
    /// state if a top panel is already open.
    private var historyButton: some View {
        Button {
            withAnimation(Design.Motion.spring) {
                vm.primarySurface = .sessions
                if vm.shellStage == .pill { vm.shellStage = .expanded }
            }
        } label: {
            iconCircle(systemName: "clock.arrow.circlepath",
                       tint: vm.primarySurface == .sessions
                             ? Design.Accent.purple : .secondary)
        }
        .buttonStyle(.plain)
        .help("History")
    }

    @ViewBuilder
    private var surfaceButtons: some View {
        // v1 surface set on the bar: Resumes, then Settings. Prompts moved
        // INTO Settings (Settings → AI tab → Manage prompts), so the bar
        // doesn't carry it as a top-level button anymore. History has its
        // own dedicated button next to + above; Calendar / Browser are
        // gated by FeatureFlags so we can bring them back in v2. Each
        // also respects the user's BarCustomization toggle.
        let bar = vm.barCustomization
        if bar.showResume {
            surfaceButton(.resumes,  icon: "doc.richtext",           label: "Resumes")
        }
        if FeatureFlags.calendarEnabled {
            surfaceButton(.calendar, icon: "calendar", label: "Calendar")
        }
        if FeatureFlags.browserEnabled {
            surfaceButton(.browser, icon: "globe", label: "Browser")
        }
        // Profile / settings button is the user's permanent escape hatch
        // into preferences (and account, API keys, etc.), so unlike the
        // other surface buttons it isn't gated by BarCustomization — it's
        // always rendered.
        surfaceButton(.settings, icon: "person.crop.circle", label: "Profile",
                      attention: vm.needsKeyForCurrentModel)
    }

    private func surfaceButton(_ surface: OverlayViewModel.PrimarySurface,
                               icon: String,
                               label: String,
                               attention: Bool = false) -> some View {
        let active = vm.primarySurface == surface && vm.shellStage != .pill
        return Button {
            withAnimation(Design.Motion.spring) {
                if active {
                    // Tapping the active surface again closes the body
                    // back to the bar-only (compact) layout — quicker
                    // than hunting for a separate close button.
                    vm.primarySurface = nil
                } else {
                    vm.primarySurface = surface
                    if vm.shellStage == .pill { vm.shellStage = .expanded }
                }
            }
        } label: {
            iconCircle(
                systemName: icon,
                tint: attention ? Design.Accent.amber
                      : (active ? Design.Accent.blue : .secondary),
                size: 12,
                fill: active ? Design.Accent.blue.opacity(0.16) : Color.white.opacity(0.04)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var workspaceButton: some View {
        WorkspaceSwitcherView()
            .frame(width: 30, height: 30)
    }

    private var permissionsMenu: some View {
        // Mode color dot removed — kept the chip design but the per-mode
        // accent dot was visual noise the user wanted gone.
        PopUpChip(
            items: { modeMenuItems() },
            label: {
                HStack(spacing: 4) {
                    Text(activeModeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(Capsule())
            }
        )
        .help("Mode and prompts")
    }

    private func modeMenuItems() -> [PopUpItem] {
        var items: [PopUpItem] = []
        items.append(.section("Built-in modes"))
        for mode in SessionMode.allCases {
            items.append(.option(
                mode.displayName,
                isSelected: vm.sessionMode == mode && vm.promptStore.activePreset == nil
            ) {
                vm.sessionMode = mode
                if let linked = vm.promptStore.linkedPreset(for: mode) {
                    vm.promptStore.activePresetID = linked.id
                } else {
                    vm.promptStore.activePresetID = nil
                }
            })
        }
        let customModes = vm.promptStore.conversationPresets.filter { $0.linkedMode == nil }
        if !customModes.isEmpty {
            items.append(.section("Custom modes"))
            for preset in customModes {
                let id = preset.id
                items.append(.option(
                    preset.name,
                    isSelected: vm.promptStore.activePresetID == id
                ) {
                    vm.promptStore.activePresetID = id
                })
            }
        }
        items.append(.option("Manage custom prompts…") {
            vm.primarySurface = .prompts
        })
        return items
    }


    private var activeModeLabel: String {
        vm.promptStore.activePreset?.name ?? vm.sessionMode.displayName
    }

    // MARK: - Right utilities

    private var modelMenu: some View {
        PopUpChip(
            items: { modelMenuItems() },
            label: {
                HStack(spacing: 4) {
                    Text(currentModelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
        )
        .help("Choose model")
    }

    private func modelMenuItems() -> [PopUpItem] {
        var items: [PopUpItem] = []
        let visibility = ModelVisibility.shared
        let providers = ["Anthropic", "OpenAI"]
        for provider in providers {
            let models = OverlayViewModel.availableModels
                .filter { $0.provider == provider && visibility.isVisible($0.id) }
            guard !models.isEmpty else { continue }
            items.append(.section(provider))
            for m in models {
                let id = m.id
                items.append(.option(m.name, isSelected: vm.selectedModel == id) {
                    vm.selectedModel = id
                })
            }
        }
        // Footer: jump to Settings → AI to manage which models appear.
        items.append(.option("Manage models…") {
            vm.primarySurface = .settings
        })
        return items
    }

    private var currentModelName: String {
        OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model"
    }

    private var micButton: some View {
        let streaming = vm.isSendingToAI
        let recording = vm.isInterviewSession || vm.isRecording
        let active = streaming || recording
        let interview = vm.sessionMode == .interview
        let idleIcon = interview ? "play.fill" : "mic"
        let idleSize: CGFloat = interview ? 10 : 12

        return Button { primaryAction() } label: {
            ZStack {
                Circle().fill(active ? Design.Accent.red.opacity(0.20) : Color.white.opacity(0.04))
                Circle().strokeBorder(
                    active ? Design.Accent.red.opacity(0.45) : Color.white.opacity(0.10),
                    lineWidth: 0.5
                )
                Image(systemName: active ? "stop.fill" : idleIcon)
                    .font(.system(size: active ? 10 : idleSize, weight: .semibold))
                    .foregroundColor(active ? Design.Accent.red : .secondary)
                    .symbolEffect(.pulse, options: active ? .repeating : .nonRepeating, value: active)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(streaming
              ? "Stop generating"
              : (recording
                 ? "Stop \(interview ? "interview" : "recording")"
                 : (interview ? "Start interview" : "Start recording")))
    }

    private func primaryAction() {
        if vm.isSendingToAI { vm.cancelStreaming(); return }
        if vm.sessionMode == .interview {
            if vm.isInterviewSession { vm.stopInterviewSession() }
            else                     { vm.startInterviewSession() }
        } else {
            vm.toggleRecording()
        }
    }

    private var sendButton: some View {
        let enabled = vm.canSend || !vm.manualInput.isEmpty
        return Button { send() } label: {
            ZStack {
                Circle().fill(enabled ? Design.Accent.blue : Color.white.opacity(0.04))
                Circle().strokeBorder(
                    enabled ? Color.white.opacity(0.22) : Color.white.opacity(0.10),
                    lineWidth: 0.5
                )
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(enabled ? .white : .secondary.opacity(0.5))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send (⏎)")
    }

    // MARK: - Helpers

    private func iconCircle(systemName: String,
                            tint: Color,
                            weight: Font.Weight = .regular,
                            size: CGFloat = 12,
                            fill: Color = Color.white.opacity(0.04)) -> some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(tint)
        }
        .frame(width: 30, height: 30)
    }

    // MARK: - Screenshot chip

    @ViewBuilder
    private var screenshotChip: some View {
        if let img = vm.pendingScreenshot {
            HStack(spacing: 8) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("Screenshot attached")
                    .font(Design.Font.tiny)
                    .foregroundColor(.secondary)
                Spacer()
                Button { vm.pendingScreenshot = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Design.Accent.blue.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.Accent.blue.opacity(0.20), lineWidth: 0.5)
            )
        }
    }

    private func send() {
        if !vm.manualInput.isEmpty { vm.showManualInput = true }
        vm.sendToAI()
    }
}
