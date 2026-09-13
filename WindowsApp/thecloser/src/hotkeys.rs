//! Global hotkeys.
//!
//! Mirrors the macOS Carbon hotkey set (Ctrl+Opt = Ctrl+Alt on Windows). They
//! fire regardless of which app is focused, so the copilot is driven without
//! ever touching the overlay. `Record` / `QuickAsk` report key-down *and*
//! key-up so push-to-talk works.

use std::collections::HashMap;

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyAction {
    /// Show / hide the overlay (Ctrl+Alt+Space).
    Toggle,
    /// Start / stop continuous recording (Ctrl+Alt+T).
    Record,
    /// Push-to-talk quick ask: record while held (Ctrl+Alt+Q).
    QuickAsk,
    /// Explain whatever's on the clipboard (Ctrl+Alt+C).
    ExplainClipboard,
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    ResizeWider,
    ResizeNarrower,
    ResizeTaller,
    ResizeShorter,
}

/// Owns the registration and translates raw events into `(action, pressed)`.
pub struct Hotkeys {
    _manager: GlobalHotKeyManager,
    by_id: HashMap<u32, HotkeyAction>,
}

impl Hotkeys {
    pub fn new() -> Result<Self, String> {
        let manager = GlobalHotKeyManager::new().map_err(|e| e.to_string())?;
        let ctrl_alt = Modifiers::CONTROL | Modifiers::ALT;
        let ctrl_shift = Modifiers::CONTROL | Modifiers::SHIFT;

        let bindings: [(Modifiers, Code, HotkeyAction); 12] = [
            (ctrl_alt, Code::Space, HotkeyAction::Toggle),
            (ctrl_alt, Code::KeyT, HotkeyAction::Record),
            (ctrl_alt, Code::KeyQ, HotkeyAction::QuickAsk),
            (ctrl_alt, Code::KeyC, HotkeyAction::ExplainClipboard),
            (ctrl_alt, Code::ArrowLeft, HotkeyAction::MoveLeft),
            (ctrl_alt, Code::ArrowRight, HotkeyAction::MoveRight),
            (ctrl_alt, Code::ArrowUp, HotkeyAction::MoveUp),
            (ctrl_alt, Code::ArrowDown, HotkeyAction::MoveDown),
            (ctrl_shift, Code::ArrowLeft, HotkeyAction::ResizeNarrower),
            (ctrl_shift, Code::ArrowRight, HotkeyAction::ResizeWider),
            (ctrl_shift, Code::ArrowUp, HotkeyAction::ResizeShorter),
            (ctrl_shift, Code::ArrowDown, HotkeyAction::ResizeTaller),
        ];

        let mut by_id = HashMap::new();
        for (mods, code, action) in bindings {
            let hk = HotKey::new(Some(mods), code);
            // A clash with an OS/other-app shortcut shouldn't abort the rest.
            if manager.register(hk).is_ok() {
                by_id.insert(hk.id(), action);
            }
        }
        Ok(Hotkeys { _manager: manager, by_id })
    }

    /// Drain all pending hotkey events as `(action, pressed)` pairs. `pressed`
    /// is `false` on key-up (used by push-to-talk).
    pub fn poll(&self) -> Vec<(HotkeyAction, bool)> {
        let mut out = Vec::new();
        let rx = GlobalHotKeyEvent::receiver();
        while let Ok(event) = rx.try_recv() {
            if let Some(&action) = self.by_id.get(&event.id) {
                out.push((action, event.state == HotKeyState::Pressed));
            }
        }
        out
    }
}
