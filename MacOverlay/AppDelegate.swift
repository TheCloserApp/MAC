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

// Subclass removes macOS constraint that blocks windows from moving above the menu bar,
// and allows becoming key so text fields work inside a nonactivatingPanel.
class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
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

        // Request Accessibility permission once at launch (needed for Option dictation).
        // Shows the system dialog only if not already granted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

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

    func setupOverlayPanel() {
        let w: CGFloat = 500, h: CGFloat = 440
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
        overlayPanel.minSize                    = NSSize(width: 420, height: 44)
        overlayPanel.alphaValue                 = 1.0  // synced via opacityObserver after setup

        let hosting = OverlayHostingView(rootView: AnyView(OverlayView().environment(vm)))
        // Disable intrinsic-size constraints so the panel controls its own size
        hosting.sizingOptions = []
        overlayPanel.contentView = hosting
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
                    PreferencesWindowController.shared.show(vm: self.vm)
                    return nil
                }
                if chars == "n" {
                    self.vm.startNewSession()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            let img = captureScreen()
            overlayPanel.alphaValue = vm.opacity
            if let img {
                Task { @MainActor in self.vm.pendingScreenshot = img }
            }
        }
    }

    private func captureScreen() -> NSImage? {
        guard let cgImg = CGWindowListCreateImage(
            .null, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]
        ) else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }

    @objc private func frontAppChanged(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontAppPID = app.processIdentifier
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
