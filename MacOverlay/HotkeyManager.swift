import Carbon.HIToolbox
import AppKit

enum HotkeyAction: Int {
    case moveLeft       = 1
    case moveRight      = 2
    case moveUp         = 3
    case moveDown       = 4
    case resizeLeft     = 5
    case resizeRight    = 6
    case resizeUp       = 7
    case resizeDown     = 8
    case screenshot     = 9
    case clipboard      = 10
    case toggle         = 11
    case record         = 12   // Ctrl+Opt+T — toggle record
    case pushToTalk     = 13   // Ctrl+Opt+Y — push-to-talk record
    case sendSelection  = 14   // Ctrl+Opt+A — copy selection + send to AI
    case resumeGenerate = 15   // Ctrl+Opt+R — clipboard as JD → generate resume
    case resumeScore    = 16   // Ctrl+Opt+M — clipboard as JD → score current resume
    case quickAsk       = 17   // Ctrl+Opt+Q — push-to-talk quick ask
    case screenshotSend = 18   // Ctrl+Shift+S — screenshot straight to AI
    case quitApp        = 19   // Ctrl+Opt+X — quit the app outright
    case answerNow      = 20   // Cmd+Return — send the live transcript now (live sessions only)
    case screenshotSendLive = 21   // Cmd+Shift+Return — screenshot straight to AI (live sessions only)
}

class HotkeyManager {
    static let shared = HotkeyManager()

    // onAction: (action, isPressed) — isPressed false means key released
    var onAction: ((HotkeyAction, Bool) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var liveSessionRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private let signature: OSType = 0x4D4F564C  // 'MOVL'

    private let ctrlOpt:   UInt32 = UInt32(controlKey | optionKey)
    private let ctrlShift: UInt32 = UInt32(controlKey | shiftKey)
    private let ctrl:      UInt32 = UInt32(controlKey)
    private let cmd:       UInt32 = UInt32(cmdKey)
    private let cmdShift:  UInt32 = UInt32(cmdKey | shiftKey)

    func register() {
        // Listen for both pressed AND released so push-to-talk works
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
        add(kVK_LeftArrow,   ctrlOpt,   .moveLeft)
        add(kVK_RightArrow,  ctrlOpt,   .moveRight)
        add(kVK_UpArrow,     ctrlOpt,   .moveUp)
        add(kVK_DownArrow,   ctrlOpt,   .moveDown)
        add(kVK_ANSI_S,      ctrlOpt,   .screenshot)
        if FeatureFlags.clipboardShortcutsEnabled {
            add(kVK_ANSI_C,  ctrlOpt,   .clipboard)
        }
        add(kVK_Space,       ctrlOpt,   .toggle)
        add(kVK_ANSI_T,      ctrlOpt,   .record)

        // Same letter as the attach-only capture (⌃⌥S), different modifier:
        // Shift means "and send it" rather than staging it in the bar.
        add(kVK_ANSI_S,      ctrlShift, .screenshotSend)

        // Ctrl+Shift resize
        add(kVK_LeftArrow,   ctrlShift, .resizeLeft)
        add(kVK_RightArrow,  ctrlShift, .resizeRight)
        add(kVK_UpArrow,     ctrlShift, .resizeUp)
        add(kVK_DownArrow,   ctrlShift, .resizeDown)

        add(kVK_ANSI_Y,      ctrlOpt,   .pushToTalk)
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

        // Quit outright — leaves nothing running. The app has no Dock or
        // menu-bar icon, so this is the only quick way to quit it.
        add(kVK_ANSI_X,      ctrlOpt,   .quitApp)
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
        setLiveSessionHotkeys(false)
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}
