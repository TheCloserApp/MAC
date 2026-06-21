# MacOverlay — Invisible AI Copilot for macOS

A native Swift overlay that floats above every app — including full-screen
calls — and is **excluded from screen capture**, so it's there for you but
never shows up in a screen share or recording. Built as a real-time
**interview / meeting copilot**: it listens, transcribes, and streams answers
you can read while you talk.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Apple Silicon](https://img.shields.io/badge/arch-arm64-black)

---

## What It Does

- 🫥 **Invisible to screen sharing** — the panel and every popover/menu it
  opens are marked `sharingType = .none`, so Zoom / Meet / Teams / QuickTime
  capture the screen *without* the overlay. No menu-bar icon either.
- 🎧 **Live transcription** — captures your mic or system audio and converts
  speech to text in real time (on-device Apple Speech, or ElevenLabs Scribe).
- 🤖 **Streaming AI answers** — pipes the live transcript to the model and
  streams a reply formatted for instant scanning. Interview mode leads with a
  verbatim opening line plus a few tight bullets.
- 🪟 **Floats everywhere** — stays on top, visible on all Spaces, and over
  other apps' full-screen mode. Draggable; movable & resizable on screen.
- 🧠 **Multi-provider** — one picker across Anthropic, OpenAI, Kimi (Moonshot),
  Grok (xAI), DeepSeek, NVIDIA NIM, and OpenRouter. Bring your own keys.
- ⌨️ **Global hotkeys** — Quick Ask (push-to-talk), dictation into the active
  app, screenshot-and-explain, explain-clipboard, move/resize the panel.

### Session modes

| Mode | Use |
|------|-----|
| **Interview** | Live interview copilot — verbatim opening line + scannable bullets, grounded in your résumé/JD context. |
| **Meeting**   | Summaries, action items, decisions, and suggested questions. |
| **Call**      | Real-time assist on a regular call. |
| **General**   | A concise floating assistant for anything else. |

Also included: **Quick Ask** (hold Fn/Globe to ask by voice without leaving
your app), **dictation** (hold Option to dictate straight into the focused
app), **screenshot → explain**, **clipboard → explain**, **session history**,
a **prompt library**, and **résumé tailoring** (import a résumé, paste a JD,
generate a tailored DOCX with before/after scoring).

---

## Build & Run

### Prerequisites
- **macOS 14.0+** (Sonoma or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- Apple Silicon (the build script targets `arm64`)

### Build
```bash
./build.sh          # compile + ad-hoc sign into build/MacOverlay.app
./build.sh --run    # build, kill any running copy, and relaunch
open build/MacOverlay.app
```

> **Intel Macs:** change `-target arm64-apple-macos14.0` to
> `-target x86_64-apple-macos14.0` in `build.sh`.

### Tests
```bash
./test.sh           # compiles & runs the pure-logic unit suite (no Xcode/SPM)
```

### Install
```bash
cp -r build/MacOverlay.app /Applications/
```
Launch at login: **System Settings → General → Login Items → +**.

---

## First-run Setup

1. **Add an API key.** Open the panel (hover/click the brand pill) → **Profile
   / Settings → AI**, and paste a key for any provider you want to use. Keys
   are stored locally in `UserDefaults`. For ElevenLabs Scribe transcription,
   add an ElevenLabs key too (otherwise on-device Apple Speech is used).
2. **Grant permissions when prompted:**
   - **Microphone** + **Speech Recognition** — live transcription.
   - **Screen Recording** — screenshots and system-audio capture
     (ScreenCaptureKit). Pre-warmed at launch.
   - **Accessibility** — only for Option-key dictation (so it can paste into
     the active app). Requested lazily on first use.

---

## Controls

- **Open / collapse:** hover or click the brand pill.
- **Move:** drag the pill anywhere, or `⌃⌥ + arrows`.
- **Resize:** drag the grip on the panel's right edge to widen/narrow it
  (the layout grows the text field to fill the space), or `⌃⇧ + arrows`.
- **New session:** `⌘N` · **Preferences:** `⌘,` (while the panel is focused).

### Global hotkeys

| Shortcut | Action |
|----------|--------|
| `⌃⌥ Space` | Show / hide the overlay |
| `⌃⌥ T` | Start / stop recording |
| `⌃⌥ Q` *or* hold `Fn`/🌐 | Quick Ask by voice (push-to-talk) |
| Hold `⌥` (Option) | Dictate into the active app |
| `⌃⌥ S` | Capture a screenshot and attach it |
| `⌃⌥ C` | Explain whatever's on the clipboard |
| `⌃⌥ A` | Send the current selection from the front app to the AI |
| `⌃⌥ R` / `⌃⌥ M` | Generate / score a résumé from the clipboard |
| `⌃⌥ arrows` | Move the panel · `⌃⇧ arrows` resize it |

Hotkeys use Carbon `RegisterEventHotKey`, so they fire globally with no
Accessibility permission required.

---

## How It Stays Invisible & On Top

```swift
// Excluded from screen capture — the core trick.
panel.sharingType = .none
// Plus NSWindow swizzling so EVERY window (panel, menus, popovers, tooltips)
// gets sharingType = .none synchronously before it ever appears on screen.

// Above the Dock and most system UI, on every Space, over full-screen apps.
panel.level             = .statusBar + 1
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

// Non-activating panel — never steals focus from the app you're in.
NSPanel(styleMask: [.nonactivatingPanel, .resizable], ...)
panel.hidesOnDeactivate = false
```

---

## Architecture

```
MacOverlay/
├── main.swift, AppDelegate.swift     # panel setup, hotkeys, screen-share guard
├── OverlayViewModel.swift            # the app's single @Observable state hub
├── OverlayContentView.swift          # pill ↔ expanded shell, surface routing
├── AIManager.swift                   # multi-provider streaming (Anthropic/OpenAI-compatible)
├── TranscriptionManager / AppleTranscriber / DictationManager
├── Controllers/                      # AIController, ResumeController
├── Stores/                           # sessions, prompts, résumé, model visibility…
├── Models/                           # ChatSession, ResumeScore, …
└── Views/                            # Shell/, Surfaces/, Panels/, Preferences/, Shared/
```

- **State:** one `@MainActor @Observable OverlayViewModel`; SwiftUI views read
  it from the environment. AppKit↔SwiftUI bridge via plain callbacks
  (`onShellStageChange`, `onWidthResize`, …).
- **Feature flags:** `FeatureFlags.swift` hides v1-out-of-scope surfaces
  (browser, peer-control, calendar, workspaces) without deleting the code.
- **Models:** the catalogue lives in `OverlayViewModel.availableModels`; ids
  route to the right provider in `AIManager` by prefix.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Blocked by Gatekeeper | System Settings → Privacy & Security → **Open Anyway**. |
| Overlay shows up in screen share | Should never happen — every window is `sharingType = .none`. File it if you see it. |
| No transcription | Grant Microphone + Speech Recognition; for system audio, grant Screen Recording. |
| Dictation does nothing | Grant Accessibility (prompted on first Option-dictation). |
| "Add an API key" | Settings → AI; the selected model's provider needs a key. |

---

## License

[MIT](LICENSE) — free to use and modify. The app charges nothing; bring your
own provider API key.
</content>
</invoke>
