import AppKit

/// Menu-bar icon that keeps TheCloser reachable after its overlay is
/// closed, so the app can stay running and watch for calls.
///
/// Shown only while idle. The menu bar is part of every screen share, so
/// the icon hides as soon as a call starts or an interview is recording.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let callPromptItem = NSMenuItem(title: "Offer to start when a call begins",
                                            action: #selector(toggleCallPrompt), keyEquivalent: "")

    private let onOpen: () -> Void
    private let isCallPromptOn: () -> Bool
    private let setCallPrompt: (Bool) -> Void

    init(onOpen: @escaping () -> Void,
         isCallPromptOn: @escaping () -> Bool,
         setCallPrompt: @escaping (Bool) -> Void) {
        self.onOpen = onOpen
        self.isCallPromptOn = isCallPromptOn
        self.setCallPrompt = setCallPrompt
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TheCloser")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "TheCloser" + AppChannel.current.nameSuffix
        }

        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open TheCloser", action: #selector(openOverlay), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        callPromptItem.target = self
        menu.addItem(callPromptItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TheCloser", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func setHidden(_ hidden: Bool) {
        statusItem.isVisible = !hidden
    }

    func menuWillOpen(_ menu: NSMenu) {
        callPromptItem.state = isCallPromptOn() ? .on : .off
    }

    @objc private func openOverlay() { onOpen() }

    @objc private func toggleCallPrompt() { setCallPrompt(!isCallPromptOn()) }

    @objc private func quit() { NSApp.terminate(nil) }
}
