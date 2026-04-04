import Cocoa
import SwiftUI
import Combine

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

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var eventTap: CFMachPort?
    private var opacityObserver: AnyCancellable?
    private let moveStep:   CGFloat = 20
    private let resizeStep: CGFloat = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        vm = OverlayViewModel()
        NSApp.setActivationPolicy(.accessory)
        setupOverlayPanel()
        setupStatusItem()
        setupKeyboardShortcuts()
        requestAccessibilityIfNeeded()

        // Keep panel alpha in sync with vm.opacity (vm publishes on MainActor already)
        opacityObserver = vm.$opacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                self?.overlayPanel.alphaValue = val
            }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCaptureScreenshot),
            name: .captureScreenshot,
            object: nil
        )

        // Hide all app windows (menus, popovers, panels) from screen capture
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyScreenShareProtectionToAllWindows),
            name: NSNotification.Name("NSWindowWillOrderOnScreenNotification"),
            object: nil
        )
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

        let hosting = NSHostingView(rootView: OverlayView().environmentObject(vm))
        // Disable intrinsic-size constraints so the panel controls its own size
        hosting.sizingOptions = []
        overlayPanel.contentView = hosting
        overlayPanel.orderFrontRegardless()
    }

    // MARK: - Accessibility permission

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }
        // Re-try tap setup whenever the app becomes active (e.g. after user grants permission)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(retryEventTapIfNeeded),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func retryEventTapIfNeeded() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        setupEventTap()
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
    //
    //  Ctrl+Option+↑↓←→   → move
    //  Ctrl+Shift+↑↓←→    → resize
    //  Ctrl+Option+S       → screenshot

    func setupKeyboardShortcuts() {
        // Local monitor: always works when our panel is key
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return event
        }

        // CGEventTap: truly global, works from any app, requires Accessibility
        setupEventTap()
    }

    private func setupEventTap() {
        guard AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // passive — won't block other apps
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                delegate.handleCGEvent(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else { return }
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleCGEvent(_ event: CGEvent) {
        let flags    = event.flags
        let keyCode  = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        let ctrlOpt  = flags.contains([.maskControl, .maskAlternate]) && !flags.contains(.maskShift) && !flags.contains(.maskCommand)
        let ctrlShift = flags.contains([.maskControl, .maskShift])    && !flags.contains(.maskAlternate) && !flags.contains(.maskCommand)

        if ctrlOpt {
            switch keyCode {
            case 123: movePanel(dx: -moveStep, dy: 0)
            case 124: movePanel(dx:  moveStep, dy: 0)
            case 125: movePanel(dx: 0, dy: -moveStep)
            case 126: movePanel(dx: 0, dy:  moveStep)
            case 1:   DispatchQueue.main.async { self.captureAndAttachScreenshot() }   // S
            case 8:   DispatchQueue.main.async { self.explainClipboard() }             // C
            case 49:  DispatchQueue.main.async { self.toggleOverlay() }                // Space
            default: return
            }
        } else if ctrlShift {
            switch keyCode {
            case 123: resizePanel(dw: -resizeStep, dh: 0)
            case 124: resizePanel(dw:  resizeStep, dh: 0)
            case 125: resizePanel(dw: 0, dh: -resizeStep)
            case 126: resizePanel(dw: 0, dh:  resizeStep)
            default: return
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

    // MARK: - Screen share protection

    @objc func applyScreenShareProtectionToAllWindows() {
        for window in NSApp.windows {
            window.sharingType = .none
        }
    }

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
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m) }
        if let t = eventTap         { CGEvent.tapEnable(tap: t, enable: false) }
    }
}
