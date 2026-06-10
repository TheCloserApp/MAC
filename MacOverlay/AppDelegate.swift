import Cocoa
import SwiftUI
import ScreenCaptureKit

// Always shows the arrow cursor over the overlay, even over text fields.
// Prevents the I-beam cursor from appearing during screen share (the overlay is hidden
// from capture but the cursor shape is still visible to the interviewer).
final class OverlayHostingView: NSHostingView<AnyView> {
    override func resetCursorRects() {
        // Do NOT call super — that would let SwiftUI register I-beam rects for text fields.
        addCursorRect(bounds, cursor: .arrow)
    }
}

// NSPanel subclass that keeps the overlay inside the visible screen in real time
// (so drag can never push it off-screen) while still allowing the panel to sit
// flush with the screen's absolute bottom — our window level is above the Dock,
// so the Dock area is a legitimate resting spot for the pill.
//
// `canBecomeKey` is overridden so text fields inside the nonactivating panel
// still accept keyboard input.
class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var f = frameRect

        // Enforce minSize ourselves. Borderless / nonactivating panels
        // don't always get the standard AppKit min-size clamping during
        // user-initiated drag-resize, which lets the user shrink the
        // panel small enough to clip its contents. Re-enforce it here so
        // every code path (programmatic AND drag) honors the minimum.
        f.size.width  = max(f.size.width,  self.minSize.width)
        f.size.height = max(f.size.height, self.minSize.height)

        // Position constraint — keep the panel on a connected screen
        // (full frame so the bottom can reach the absolute edge; the
        // visibleFrame caps the top to leave room for the menu bar).
        guard let screen = screen ?? NSScreen.main else { return f }
        let sf = screen.frame
        let vf = screen.visibleFrame
        f.origin.x = min(max(f.origin.x, sf.minX), sf.maxX - f.size.width)
        f.origin.y = min(max(f.origin.y, sf.minY), vf.maxY - f.size.height)
        return f
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayPanel: NSPanel!
    var statusItem: NSStatusItem!
    var vm: OverlayViewModel!

    private var localKeyMonitor: Any?
    private var optionKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var fnKeyDown        = false   // tracks Fn/Globe key for quick-ask push-to-talk
    private var dictationKeyDown = false   // tracks Option key for dictation push-to-talk
    private var dictationManager: DictationManager?
    private var lastFrontAppPID: pid_t = 0
    private let moveStep:   CGFloat = 20
    private let resizeStep: CGFloat = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        vm = OverlayViewModel()
        NSApp.setActivationPolicy(.accessory)
        setupOverlayPanel()
        setupStatusItem()
        setupKeyboardShortcuts()

        // With @Observable the ViewModel no longer publishes a Combine $opacity.
        // Use a direct callback so we only do the work that matters.
        vm.onOpacityChange = { [weak self] val in
            self?.overlayPanel.alphaValue = val
        }
        overlayPanel.alphaValue = vm.opacity

        // Animate the NSPanel between pill and expanded sizes whenever
        // the VM transitions stage. The bottom edge stays pinned so the
        // bar doesn't visibly jump as the panel grows / shrinks.
        vm.onShellStageChange = { [weak self] stage in
            if stage.isOnScreen { self?.updatePillAnchor() }
            self?.animateShellFrame(stage: stage)
        }

        // Re-fire the resize whenever the floating pill popup
        // (resume score / generated resume / quick-ask) appears or
        // disappears in pill mode — the panel needs to grow tall enough
        // to host the popup above the brand pill.
        vm.onPillPopupChange = { [weak self] _ in
            guard let self, let stage = self.vm?.shellStage else { return }
            self.animateShellFrame(stage: stage)
        }

        // The expanded panel adapts to whether a surface is open
        // (compact bar-only vs. full body). Surface changes need to
        // re-fire the same resize so the panel matches.
        vm.onPrimarySurfaceChange = { [weak self] _ in
            guard let self, let stage = self.vm?.shellStage else { return }
            self.animateShellFrame(stage: stage)
        }

        // Watch the panel's position so the shell can flip the sidebar to the
        // correct side as the user drags the overlay around the screen.
        updatePillAnchor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: overlayPanel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didResizeNotification,
            object: overlayPanel
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCaptureScreenshot),
            name: .captureScreenshot,
            object: nil
        )

        // Pre-warm Screen Recording permission so the dialog appears at launch,
        // not mid-session when the user first tries to record system audio.
        Task {
            _ = try? await SCShareableContent.current
        }

        // Accessibility permission is needed for Option-key dictation, which
        // pastes into the active app. We DON'T prompt at launch — the system
        // dialog stalls applicationDidFinishLaunching and most users never
        // touch dictation. The prompt is shown lazily on first dictation
        // attempt; see ensureAccessibilityPrompted().

        // Track which app was frontmost before any hotkey fires
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // ── Screen-share / screenshot protection ──────────────────────────────
        // Notifications and timers are async — a screen-sharing tool can capture
        // a menu window in the gap before they fire.  Swizzling NSWindow's three
        // "order on screen" methods is the only synchronous hook that runs in the
        // SAME call-stack as the window appearing, before any capture frame occurs.
        NSWindow.installScreenShareProtection()
    }

    // MARK: - Overlay Panel

    /// `.pill` — small capsule that just shows the brand logo.
    static let collapsedSize = NSSize(width: 360, height: 80)
    /// `.pill` with a floating result popup (resume score / generated
    /// resume / quick-ask) anchored above the brand. Grows the panel
    /// tall and wide enough to host the popup without expanding the
    /// shell — the user still sees only the pill + the popup card.
    static let pillWithPopupSize = NSSize(width: 480, height: 360)
    /// `.expanded` with no `primarySurface` — InputBar only, single row.
    static let expandedCompactSize = NSSize(width: 620, height: 84)
    /// `.expanded` with a `primarySurface` set — full shell: top header
    /// + body + InputBar.
    static let expandedSize  = NSSize(width: 620, height: 500)

    /// Last-known full-state size. Captured whenever the user transitions
    /// from full → mini so we can restore exactly what they had on expand,
    /// and so the mini state preserves the user's manual panel width.
    private var lastFullSize: NSSize = expandedSize

    @MainActor
    func setupOverlayPanel() {
        // If the user lands on the welcome / sign-in flow at launch, the
        // hero content needs the full panel — starting at the pill size
        // (360×80) leaves the content clipped out the bottom of the
        // window. Decide the initial stage + size BEFORE the panel goes
        // on screen so there's no visible resize jump.
        let needsHeroLayout = !vm.auth.isSignedIn || vm.showOnboarding
        if needsHeroLayout {
            vm.shellStage = .expanded
        }
        let initial = needsHeroLayout ? Self.expandedSize : Self.collapsedSize
        let w: CGFloat = initial.width, h: CGFloat = initial.height
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let frame = NSRect(x: sf.midX - w / 2, y: sf.maxY - h - 20, width: w, height: h)

        overlayPanel = UnconstrainedPanel(
            contentRect: frame,
            // No .fullSizeContentView — that lets us resize height freely
            styleMask:   [.nonactivatingPanel, .resizable],
            backing:     .buffered,
            defer:       false
        )
        overlayPanel.level                      = .statusBar + 1
        overlayPanel.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayPanel.isOpaque                   = false
        overlayPanel.backgroundColor            = .clear
        overlayPanel.hasShadow                  = true
        overlayPanel.titlebarAppearsTransparent = true
        overlayPanel.titleVisibility            = .hidden
        overlayPanel.isMovableByWindowBackground = true
        overlayPanel.hidesOnDeactivate          = false
        overlayPanel.isFloatingPanel            = true
        overlayPanel.becomesKeyOnlyIfNeeded     = true
        overlayPanel.sharingType                = .none
        // Initial minSize matches the launch stage; `animateShellFrame`
        // updates it on every stage transition so the user can never
        // shrink the panel below what's visible.
        overlayPanel.minSize                    = needsHeroLayout ? Self.expandedMinSize : Self.pillMinSize
        overlayPanel.alphaValue                 = 1.0  // synced via opacityObserver after setup

        let hosting = OverlayHostingView(rootView: AnyView(OverlayView().environment(vm)))
        // Disable intrinsic-size constraints so the panel controls its own size
        hosting.sizingOptions = []
        overlayPanel.contentView = hosting

        // Restore last-used position (constrainFrameRect will clamp if the saved
        // origin is on a monitor that's no longer connected).
        restorePanelOrigin()

        overlayPanel.orderFrontRegardless()
    }

    // MARK: - Status Bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Overlay")
            btn.image?.size = NSSize(width: 18, height: 18)
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Overlay", action: #selector(toggleOverlay), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",           action: #selector(quitApp),       keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Keyboard Shortcuts

    func setupKeyboardShortcuts() {
        // Carbon RegisterEventHotKey: global, no Accessibility needed, never auto-disabled
        HotkeyManager.shared.onAction = { [weak self] action, isPressed in
            guard let self else { return }
            // Most actions only fire on press; pushToTalk uses both press and release
            switch action {
            case .moveLeft:    if isPressed { self.movePanel(dx: -self.moveStep, dy: 0) }
            case .moveRight:   if isPressed { self.movePanel(dx:  self.moveStep, dy: 0) }
            case .moveUp:      if isPressed { self.movePanel(dx: 0, dy:  self.moveStep) }
            case .moveDown:    if isPressed { self.movePanel(dx: 0, dy: -self.moveStep) }
            case .resizeLeft:  if isPressed { self.resizePanel(dw: -self.resizeStep, dh: 0) }
            case .resizeRight: if isPressed { self.resizePanel(dw:  self.resizeStep, dh: 0) }
            case .resizeUp:    if isPressed { self.resizePanel(dw: 0, dh:  self.resizeStep) }
            case .resizeDown:  if isPressed { self.resizePanel(dw: 0, dh: -self.resizeStep) }
            case .screenshot:  if isPressed { self.captureAndAttachScreenshot() }
            case .clipboard:   if isPressed { self.explainClipboard() }
            case .toggle:      if isPressed { self.toggleOverlay() }
            case .record:      if isPressed { self.hotkeyRecord() }
            case .pushToTalk:  if isPressed { self.hotkeyRecord() }
            case .sendSelection:  if isPressed { self.sendSelection() }
            case .resumeGenerate: if isPressed { self.resumeFromClipboard() }
            case .resumeScore:    if isPressed { self.scoreResumeFromClipboard() }
            case .quickAsk:       break   // handled via Fn flagsChanged monitor
            }
        }
        HotkeyManager.shared.register()

        // Fn/Globe + Option key monitoring via both global and local flagsChanged monitors.
        // Global fires when another app is frontmost; local fires when overlay panel is key.
        // Both call the same shared handler so nothing is missed.
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        optionKeyMonitor  = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)  { event in
            flagsHandler(event); return event
        }

        // Local monitor as fallback when overlay panel is key
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Handle ⌘, for preferences and ⌘N for new session while the
            // overlay is key. Return nil to consume the event so it doesn't
            // propagate to text fields.
            if let self,
               event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers {
                if chars == "," {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        PreferencesWindowController.shared.show(vm: self.vm)
                    }
                    return nil
                }
                if chars == "n" {
                    Task { @MainActor [weak self] in
                        self?.vm.startNewSession()
                    }
                    return nil
                }
            }
            self?.handleKey(event)
            return event
        }

    }

    // MARK: - Send selection (Ctrl+Opt+A)

    func sendSelection() {
        // Use the tracked PID of the app that was active before our hotkey fired
        let pid = lastFrontAppPID
        guard pid != 0 else { return }

        let src     = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty else { return }
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in
                self.vm.showManualInput = true
                self.vm.manualInput     = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.vm.sendToAI()
            }
        }
    }

    func hotkeyRecord() {
        DispatchQueue.main.async {
            Task { @MainActor in self.vm.hotkeyToggleRecord() }
        }
    }

    func resumeFromClipboard() {
        DispatchQueue.main.async { [self] in
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in self.vm.generateResumeFromClipboard() }
        }
    }

    func scoreResumeFromClipboard() {
        DispatchQueue.main.async { [self] in
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in self.vm.scoreResumeFromClipboard() }
        }
    }

    // MARK: - Flags changed (Fn + Option) — shared by global + local monitors

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods    = event.modifierFlags.intersection([.option, .control, .shift, .command, .function])
        let fnDown  = mods.contains(.function)
        let optDown = mods.contains(.option) && !mods.contains(.control)
                                              && !mods.contains(.shift)
                                              && !mods.contains(.command)

        // ── Fn/Globe: push-to-talk quick ask ────────────────────────
        // Hold Fn → start recording; release Fn → stop & send to AI
        if fnDown && !fnKeyDown {
            fnKeyDown = true
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in
                if !vm.isQuickAsking && !vm.isQuickAskSending { vm.toggleQuickAsk() }
            }
        } else if !fnDown && fnKeyDown {
            fnKeyDown = false
            Task { @MainActor in
                if vm.isQuickAsking { vm.toggleQuickAsk() }
            }
        }

        // ── Option alone: push-to-talk dictation into active app ────
        if optDown && !dictationKeyDown {
            dictationKeyDown = true
            ensureAccessibilityPrompted()
            let pid = lastFrontAppPID
            let mgr = DictationManager()
            dictationManager = mgr

            Task { @MainActor in
                if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
                vm.isDictating   = true
                vm.dictationText = ""
            }
            mgr.onTranscript = { [weak self] text in
                Task { @MainActor in self?.vm.dictationText = text }
            }
            mgr.onPasted = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.vm.isDictating   = false
                    self.vm.dictationText = ""
                    self.vm.statusMessage = "✓ Dictation pasted"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if self.vm.statusMessage == "✓ Dictation pasted" { self.vm.statusMessage = "" }
                }
            }
            mgr.onStatus = { [weak self] msg in
                Task { @MainActor in self?.vm.statusMessage = msg }
            }
            Task { @MainActor [weak self, weak mgr] in
                guard let self else { return }
                mgr?.start(targetPID: pid, elevenLabsAPIKey: self.vm.elevenLabsAPIKey)
            }

        } else if !optDown && dictationKeyDown {
            dictationKeyDown = false
            dictationManager?.stop()
            dictationManager = nil
            Task { @MainActor in
                vm.isDictating   = false
                vm.dictationText = ""
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let code  = event.keyCode
        if flags == [.control, .option] {
            switch code {
            case 123: movePanel(dx: -moveStep, dy: 0)
            case 124: movePanel(dx:  moveStep, dy: 0)
            case 125: movePanel(dx: 0, dy: -moveStep)
            case 126: movePanel(dx: 0, dy:  moveStep)
            case 1:   captureAndAttachScreenshot()     // S
            case 8:   explainClipboard()               // C
            case 17:  hotkeyRecord()  // T
            case 49:  toggleOverlay()                  // Space
            default: break
            }
        } else if flags == [.control, .shift] {
            switch code {
            case 123: resizePanel(dw: -resizeStep, dh: 0)
            case 124: resizePanel(dw:  resizeStep, dh: 0)
            case 125: resizePanel(dw: 0, dh: -resizeStep)
            case 126: resizePanel(dw: 0, dh:  resizeStep)
            default: break
            }
        }
    }

    private func movePanel(dx: CGFloat, dy: CGFloat) {
        DispatchQueue.main.async { [self] in
            let o = overlayPanel.frame.origin
            overlayPanel.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy))
        }
    }

    private func resizePanel(dw: CGFloat, dh: CGFloat) {
        DispatchQueue.main.async { [self] in
            let f  = overlayPanel.frame
            let nw = max(overlayPanel.minSize.width,  f.width  + dw)
            let nh = max(overlayPanel.minSize.height, f.height + dh)
            // Anchor top edge: when height grows, origin moves down; when shrinks, moves up
            let newOriginY = f.origin.y + (f.height - nh)
            overlayPanel.setFrame(
                NSRect(x: f.origin.x, y: newOriginY, width: nw, height: nh),
                display: true, animate: false
            )
        }
    }

    // MARK: - Clipboard explain

    func explainClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        // Show overlay if hidden
        if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
        Task { @MainActor in
            vm.showManualInput  = true
            vm.manualInput      = "Explain this: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            vm.sendToAI()
        }
    }

    // MARK: - Screenshot

    @objc func onCaptureScreenshot() { captureAndAttachScreenshot() }

    func captureAndAttachScreenshot() {
        DispatchQueue.main.async { [self] in
            overlayPanel.alphaValue = 0
        }
        // Wait for the overlay to hide itself, capture via ScreenCaptureKit,
        // restore alpha, and attach the image on the main actor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let img = await self.captureScreen()
            self.overlayPanel.alphaValue = self.vm.opacity
            if let img { self.vm.pendingScreenshot = img }
        }
    }

    /// Async capture via ScreenCaptureKit. Full-screen shot of the main
    /// display, excluding no windows. Returns nil on permission denial or
    /// any SCStream error — users see a silent no-op which matches the
    /// previous behaviour.
    private func captureScreen() async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width  = Int(display.width)
            cfg.height = Int(display.height)
            cfg.capturesAudio = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: cfg
            )
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
    }

    @objc private func frontAppChanged(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontAppPID = app.processIdentifier
        }
    }

    private var anchorUpdateTask: Task<Void, Never>?

    private static let savedOriginDefaultsKey = "MacOverlay.savedPanelOrigin"

    @objc private func panelDidMove(_ n: Notification) {
        anchorUpdateTask?.cancel()
        anchorUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self = self else { return }
            // Only update sidebar order when expanded — no visual change when collapsed.
            if self.vm?.isShellExpanded == true { self.updatePillAnchor() }
            self.persistPanelOrigin()
        }
    }

    private func persistPanelOrigin() {
        guard let panel = overlayPanel else { return }
        let p = panel.frame.origin
        UserDefaults.standard.set([p.x, p.y], forKey: Self.savedOriginDefaultsKey)
    }

    private func restorePanelOrigin() {
        guard let panel = overlayPanel,
              let arr = UserDefaults.standard.array(forKey: Self.savedOriginDefaultsKey) as? [CGFloat],
              arr.count == 2 else { return }
        let saved = NSPoint(x: arr[0], y: arr[1])
        // Only restore if the saved point lies on a currently-connected screen.
        // Otherwise the pill would land on a detached monitor and vanish.
        let onScreen = NSScreen.screens.contains { $0.frame.contains(saved) }
        guard onScreen else {
            UserDefaults.standard.removeObject(forKey: Self.savedOriginDefaultsKey)
            return
        }
        panel.setFrameOrigin(saved)
    }

    /// Update which screen quadrant the panel is in so the sidebar can flip
    /// its vertical item order. Never repositions the panel.
    @MainActor
    func updatePillAnchor() {
        guard let panel = overlayPanel,
              let screen = panel.screen ?? NSScreen.main,
              let vm else { return }
        let frame  = panel.frame
        let bounds = screen.visibleFrame
        let isTrailing = frame.midX > bounds.midX
        let isBottom   = frame.midY < bounds.midY
        let newAnchor: OverlayViewModel.PillAnchor
        switch (isTrailing, isBottom) {
        case (false, false): newAnchor = .topLeading
        case (true,  false): newAnchor = .topTrailing
        case (false, true):  newAnchor = .bottomLeading
        case (true,  true):  newAnchor = .bottomTrailing
        }
        // Direct set — no animation. Collapsed view doesn't read pillAnchor,
        // and expanded sidebar just reorders instantly (transitions are off).
        vm.pillAnchor = newAnchor
    }

    /// MINIMUM panel size — the user can manually resize, but never below
    /// this. Two values: pill (just the brand) and expanded (wide enough
    /// for every visible bar element).
    static let pillMinSize             = NSSize(width: 240, height: 60)
    static let expandedCompactMinSize  = NSSize(width: 600, height: 80)
    static let expandedMinSize         = NSSize(width: 600, height: 340)

    /// Resize the panel for the given shell stage. Within `.expanded`
    /// the height also adapts to whether a `primarySurface` is open:
    ///   - no surface  → bar-only height (compact)
    ///   - surface set → full height (top card + body + bar)
    /// Anchor: bottom is always pinned, so the bar stays put as the
    /// panel grows or shrinks above it. The pill itself is the same
    /// physical affordance — keeping the bottom edge fixed means the
    /// brand icon doesn't visibly jump as the shell expands or collapses.
    @MainActor
    func animateShellFrame(stage: OverlayViewModel.ShellStage) {
        guard let panel = overlayPanel else { return }
        let cur = panel.frame

        // Capture the user's manual size whenever the panel is currently
        // wider than the pill width. Without this, any drag-resize would
        // be lost on the first pill collapse — and re-expanding would
        // snap back to the default width.
        let curIsExpandedLayout = cur.size.width >= Self.expandedCompactMinSize.width
        if curIsExpandedLayout { lastFullSize = cur.size }

        let preservedWidth: CGFloat
        if stage == .pill {
            preservedWidth = Self.collapsedSize.width
        } else if curIsExpandedLayout {
            preservedWidth = cur.size.width
        } else {
            preservedWidth = lastFullSize.width
        }

        let surfaceOpen = vm.primarySurface != nil
        let target: NSSize
        switch stage {
        case .pill:
            target = vm.hasPillPopup ? Self.pillWithPopupSize : Self.collapsedSize
        case .expanded:
            if surfaceOpen {
                target = NSSize(
                    width:  preservedWidth,
                    height: max(lastFullSize.height, Self.expandedSize.height)
                )
            } else {
                target = NSSize(width: preservedWidth, height: Self.expandedCompactSize.height)
            }
        }

        let minForStage: NSSize
        switch stage {
        case .pill:     minForStage = Self.pillMinSize
        case .expanded: minForStage = surfaceOpen ? Self.expandedMinSize : Self.expandedCompactMinSize
        }
        panel.minSize = minForStage

        // Always bottom-anchor. The bar lives at the bottom of every
        // non-pill stage, and the pill itself is the same physical
        // affordance — so keeping the panel's bottom edge fixed means
        // the brand icon stays in the same vertical spot whether you
        // expand the shell or collapse it back down. The previous
        // top-anchor for `.pill` made the icon visibly jump up to the
        // top edge of where the expanded panel used to be.
        let newX = cur.origin.x
        let newY: CGFloat = cur.origin.y

        // Drive the panel resize through NSAnimationContext so the
        // duration / curve match the SwiftUI spring inside the panel.
        // `setFrame(animate: true)` uses NSWindow.animationResizeTime
        // (proportional to delta) which runs slower on big size changes
        // and visibly desyncs from SwiftUI — content jitters because the
        // panel is still resizing while SwiftUI has already settled.
        let target_ = NSRect(x: newX, y: newY, width: target.width, height: target.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target_, display: true)
        }
    }

    // Screen share protection is handled by NSWindow.installScreenShareProtection()
    // called at launch — see the extension below AppDelegate.

    // MARK: - Menu actions

    @objc func toggleOverlay() {
        if overlayPanel.isVisible { overlayPanel.orderOut(nil) }
        else                      { overlayPanel.orderFrontRegardless() }
    }

    @objc func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame, pf = overlayPanel.frame
        overlayPanel.setFrameOrigin(NSPoint(x: sf.midX - pf.width / 2, y: sf.maxY - pf.height - 20))
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    /// Show the Accessibility permission dialog the first time the user
    /// actually invokes dictation. Idempotent: subsequent invocations
    /// short-circuit once the system reports trust.
    private var didPromptForAccessibility = false
    private func ensureAccessibilityPrompted() {
        if AXIsProcessTrusted() { return }
        if didPromptForAccessibility { return }
        didPromptForAccessibility = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The session store debounces token-driven writes; flush whatever
        // hasn't been written yet so a mid-stream quit doesn't lose
        // the last few chunks.
        SessionStore.shared.flushPendingPersist()
    }

    deinit {
        if let m = localKeyMonitor   { NSEvent.removeMonitor(m) }
        if let m = optionKeyMonitor  { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        HotkeyManager.shared.unregister()
        dictationManager?.stop()
    }
}

// MARK: - NSWindow screen-share protection (swizzle)
//
// Swizzling the three "order on screen" entry points guarantees that EVERY
// window this app creates — overlay panel, SwiftUI popovers, NSMenu dropdowns,
// tooltips, sheets — has sharingType = .none before it ever appears on screen.
// Notifications and timers fire too late (after capture can already occur);
// swizzling runs synchronously in the same call-stack as the window appearing.

import ObjectiveC.runtime

extension NSWindow {

    static func installScreenShareProtection() {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.orderFront(_:)),
             #selector(NSWindow._sp_orderFront(_:))),
            (#selector(NSWindow.orderFrontRegardless),
             #selector(NSWindow._sp_orderFrontRegardless)),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)),
             #selector(NSWindow._sp_makeKeyAndOrderFront(_:))),
        ]
        for (orig, swiz) in pairs {
            guard
                let origMethod = class_getInstanceMethod(NSWindow.self, orig),
                let swizMethod = class_getInstanceMethod(NSWindow.self, swiz)
            else { continue }
            method_exchangeImplementations(origMethod, swizMethod)
        }
    }

    @objc func _sp_orderFront(_ sender: Any?) {
        sharingType = .none
        _sp_orderFront(sender)            // calls original after swap
    }

    @objc func _sp_orderFrontRegardless() {
        sharingType = .none
        _sp_orderFrontRegardless()        // calls original after swap
    }

    @objc func _sp_makeKeyAndOrderFront(_ sender: Any?) {
        sharingType = .none
        _sp_makeKeyAndOrderFront(sender)  // calls original after swap
    }
}
