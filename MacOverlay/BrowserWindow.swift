import AppKit
import SwiftUI

/// The browser, popped out of the overlay shell into a window of its own.
///
/// Why a second window: the overlay shows one surface at a time, so keeping
/// a page open meant giving up the interview panel. Detached, the browser
/// sits beside the overlay and both are on screen at once — the page in one
/// window, the live answer in the other.
///
/// It's an `NSPanel` for the same reasons the overlay is: it has to follow
/// the user across Spaces, never steal activation from whatever they're
/// actually working in, and stay out of screen captures. Capture exclusion
/// comes for free — `NSWindow.installScreenShareProtection()` swizzles the
/// order-front entry points, so `sharingType` is stamped on this panel
/// before it ever reaches the screen, and `applyScreenShareVisibility`
/// re-stamps it live because it walks `NSApp.windows`.
@MainActor
final class BrowserWindow: NSObject, NSWindowDelegate {
    static let shared = BrowserWindow()
    private override init() { super.init() }

    private var panel: NSPanel?
    private weak var vm: OverlayViewModel?

    var isOpen: Bool { panel != nil }

    // MARK: - Open / close

    /// Show the detached window, or bring it forward if it's already up.
    func present(vm: OverlayViewModel) {
        self.vm = vm

        if let panel {
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let panel = DetachedBrowserPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask:   [.nonactivatingPanel, .titled, .closable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        )
        panel.title                      = "Browser"
        panel.titleVisibility            = .hidden
        panel.titlebarAppearsTransparent = true
        // One level below the overlay (.statusBar + 1): when the two windows
        // overlap, the one the hotkeys drive stays on top.
        panel.level                      = .statusBar
        panel.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel            = true
        panel.hidesOnDeactivate          = false
        // The overlay sets this true so it only takes key for a text field.
        // A web page needs every keystroke, so this window takes key on a
        // plain click — still without activating the app.
        panel.becomesKeyOnlyIfNeeded     = false
        panel.isOpaque                   = false
        // A solid fill rather than the overlay's `.clear`: this window has a
        // titlebar, and a clear background would leave that strip see-through
        // to the desktop above the tab bar. Same charcoal as the shell, so
        // the transparent titlebar blends into the content.
        panel.backgroundColor            = NSColor(Design.Surface.shellFill)
        panel.hasShadow                  = true
        panel.minSize                    = NSSize(width: 460, height: 340)
        panel.sharingType                = NSWindow.desiredSharingType
        panel.delegate                   = self
        // We hold the only strong reference and drop it in windowWillClose;
        // letting AppKit release it on close would leave that reference
        // dangling.
        panel.isReleasedWhenClosed       = false

        let root = BrowserShellSurface(isDetached: true)
            .environment(vm)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.Surface.shellFill)
        panel.contentView = NSHostingView(rootView: root)

        // Remembers size and position across pop-outs and across launches.
        // Only center it when there's nothing saved to restore.
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if panel.frame.origin == .zero { center(panel) }

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Close the window from our side (the "put back in overlay" button).
    /// Clears the delegate first so this doesn't re-enter through
    /// `windowWillClose` and undo state the caller has already set.
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.contentView = nil
        panel.close()
    }

    /// Bring an already-open window forward — used by the placeholder the
    /// overlay shows while the browser is detached.
    func focus() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Mirrors the overlay's collapse/expand hotkey. Hiding the overlay has
    /// to hide this window too: a window that ⌃⌥Space can't take off screen
    /// defeats the point of a hotkey you reach for in a hurry.
    func setVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil
        panel = nil
        // The close button re-embeds the browser rather than throwing the
        // tabs away — same tabs, back inside the overlay shell.
        vm?.browserDetached = false
    }

    // MARK: - Placement

    private static let frameAutosaveName = "thecloser.browserWindow"

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = panel.frame
        f.size.width  = min(f.width,  vf.width  - 40)
        f.size.height = min(f.height, vf.height - 40)
        f.origin.x = vf.midX - f.width / 2
        f.origin.y = vf.midY - f.height / 2
        panel.setFrame(f, display: false)
    }
}

/// A titled panel can normally take key on its own. The override is here
/// because `.nonactivatingPanel` makes AppKit conservative about it, and a
/// browser that can't receive keystrokes is not a browser.
private final class DetachedBrowserPanel: NSPanel {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }
}
