import Carbon.HIToolbox
import AppKit

enum HotkeyAction: Int {
    case moveLeft       = 1    // Cmd+Shift+arrows, only while the overlay is showing
    case moveRight      = 2
    case moveUp         = 3
    case moveDown       = 4
    case resizeLeft     = 5    // Ctrl+Shift+arrows
    case resizeRight    = 6
    case resizeUp       = 7
    case resizeDown     = 8
    case clipboard      = 10
    case toggle         = 11   // Ctrl+Opt+Space — show / hide the overlay
    case sendSelection  = 14   // Ctrl+Opt+A — copy selection + send to AI
    case resumeGenerate = 15   // Ctrl+Opt+R — clipboard as JD → generate resume
    case resumeScore    = 16   // Ctrl+Opt+M — clipboard as JD → score current resume
    case quickAsk       = 17   // Ctrl+Opt+Q — push-to-talk quick ask
    case answerNow      = 20   // Cmd+Return — send the live transcript now (live sessions only)
    case screenshotSendLive = 21   // Cmd+Shift+Return — screenshot straight to AI (live sessions only)
}

class HotkeyManager {
    static let shared = HotkeyManager()

    // onAction: (action, isPressed) — isPressed false means key released
    var onAction: ((HotkeyAction, Bool) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var moveRefs: [EventHotKeyRef?] = []
    private var liveSessionRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private let signature: OSType = 0x4D4F564C  // 'MOVL'

    private let ctrlOpt:   UInt32 = UInt32(controlKey | optionKey)
    private let ctrlShift: UInt32 = UInt32(controlKey | shiftKey)
    private let cmd:       UInt32 = UInt32(cmdKey)
    private let cmdShift:  UInt32 = UInt32(cmdKey | shiftKey)

    func register() {
        // Listen for both pressed AND released (the handler reports which)
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, inEvent, refcon -> OSStatus in
                guard let inEvent, let refcon else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    inEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                if let action = HotkeyAction(rawValue: Int(hkID.id)) {
                    let isPressed = GetEventKind(inEvent) == kEventHotKeyPressed
                    DispatchQueue.main.async { manager.onAction?(action, isPressed) }
                }
                return noErr
            },
            2,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        // Ctrl+Opt shortcuts
        if FeatureFlags.clipboardShortcutsEnabled {
            add(kVK_ANSI_C,  ctrlOpt,   .clipboard)
        }
        add(kVK_Space,       ctrlOpt,   .toggle)

        // Ctrl+Shift resize
        add(kVK_LeftArrow,   ctrlShift, .resizeLeft)
        add(kVK_RightArrow,  ctrlShift, .resizeRight)
        add(kVK_UpArrow,     ctrlShift, .resizeUp)
        add(kVK_DownArrow,   ctrlShift, .resizeDown)

        if FeatureFlags.clipboardShortcutsEnabled {
            add(kVK_ANSI_A,  ctrlOpt,   .sendSelection)
        }
        // Résumé hotkeys (generate / score) only registered when the résumé
        // surface is enabled — see FeatureFlags.resumesEnabled.
        if FeatureFlags.resumesEnabled {
            add(kVK_ANSI_R,  ctrlOpt,   .resumeGenerate)
            add(kVK_ANSI_M,  ctrlOpt,   .resumeScore)
        }
        if FeatureFlags.quickAskEnabled {
            add(kVK_ANSI_Q,  ctrlOpt,   .quickAsk)
        }
    }

    /// ⌘⇧ + arrows move the overlay, but only while it's on screen. It's
    /// also macOS's "select to the start / end of the line" in every text
    /// field, and a global hotkey takes it from every app, so it's given
    /// back whenever the overlay is hidden.
    func setMoveHotkeys(_ active: Bool) {
        if active {
            guard moveRefs.isEmpty else { return }
            moveRefs = [
                registerHotKey(kVK_LeftArrow,  cmdShift, .moveLeft),
                registerHotKey(kVK_RightArrow, cmdShift, .moveRight),
                registerHotKey(kVK_UpArrow,    cmdShift, .moveUp),
                registerHotKey(kVK_DownArrow,  cmdShift, .moveDown),
            ]
        } else {
            moveRefs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
            moveRefs = []
        }
    }

    /// ⌘⏎ and ⌘⇧⏎ exist only while a live session is recording. A global
    /// hotkey swallows the combo in every app, and ⌘⏎ is "send" in Slack,
    /// Gmail and many others, as well as "Start" on our own setup screen.
    func setLiveSessionHotkeys(_ active: Bool) {
        if active {
            guard liveSessionRefs.isEmpty else { return }
            liveSessionRefs = [
                registerHotKey(kVK_Return, cmd,      .answerNow),
                registerHotKey(kVK_Return, cmdShift, .screenshotSendLive),
            ]
        } else {
            liveSessionRefs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
            liveSessionRefs = []
        }
    }

    private func add(_ keyCode: Int, _ modifiers: UInt32, _ action: HotkeyAction) {
        refs.append(registerHotKey(keyCode, modifiers, action))
    }

    private func registerHotKey(_ keyCode: Int, _ modifiers: UInt32, _ action: HotkeyAction) -> EventHotKeyRef? {
        let id = EventHotKeyID(signature: signature, id: UInt32(action.rawValue))
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        return ref
    }

    func unregister() {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs = []
        setMoveHotkeys(false)
        setLiveSessionHotkeys(false)
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}
