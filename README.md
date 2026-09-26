# thecloser — Invisible AI Copilot for macOS

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
  speech to text in real time with ElevenLabs Scribe (Apple Speech is also
  available). English by default; other languages in Preferences.
- 🤖 **Streaming AI answers** — pipes the live transcript to the model and
  streams a reply formatted for instant scanning. Interview mode leads with a
  verbatim opening line plus a few tight bullets.
- 🪟 **Floats everywhere** — stays on top, visible on all Spaces, and over
  other apps' full-screen mode. Draggable; movable & resizable on screen.
- 🧠 **One key, many models** — every model runs through OpenRouter: Claude,
  GPT, Gemini, Grok and Kimi from one picker. Bring your own OpenRouter and
  ElevenLabs keys.
- ⌨️ **Global hotkeys** — ⌘⏎ answer now and ⌘⇧⏎ screenshot to the AI during
  an interview, plus show/hide and move/resize the panel.

### Session modes

| Mode | Use |
|------|-----|
| **Interview** | Live interview copilot — verbatim opening line + scannable bullets, grounded in your résumé/JD context. |
| **Regular call** | Beta builds only: real-time assist on a regular call. |

Also included: **screenshot → explain**, **session history**, a **prompt
library**, and a built-in **browser** with tabs (hidden from screen sharing
like everything else).

Quick Ask, dictation, the clipboard shortcuts and résumé tailoring are still
in the code but switched off in every build while v1 focuses on the
interview helper. See `FeatureFlags.swift`.

---

## Build & Run

### Prerequisites
- **macOS 14.0+** (Sonoma or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- Apple Silicon (the build script targets `arm64`)

### Build
```bash
./build.sh                    # Dev build → "build/thecloser Dev.app"
./build.sh --run              # build Dev, quit any running Dev copy, relaunch
./build.sh --channel beta     # Beta build → "build/thecloser Beta.app"
./build.sh --channel prod     # Production build → build/thecloser.app
```

> **Intel Macs:** change `-target arm64-apple-macos14.0` to
> `-target x86_64-apple-macos14.0` in `build.sh`.

### Tests
```bash
./test.sh           # compiles & runs the pure-logic unit suite (no Xcode/SPM)
```

### Install
```bash
cp -r build/thecloser.app /Applications/
```
Launch at login: **System Settings → General → Login Items → +**.

---

## Environments & releases

The app ships in three channels, all from the same code. Each has its own
bundle ID, app name and data folder, so they can be installed side by side
without sharing settings, sessions or privacy permissions. Dev and Beta show
a small **DEV** / **BETA** tag on the brand pill.

| Channel | Build | Bundle ID | Data folder | Features |
|---|---|---|---|---|
| Dev | `./build.sh` | `tech.thecloser.mac.dev` | `MacOverlay Dev` | Interview helper + beta features |
| Beta | `./build.sh --channel beta` | `tech.thecloser.mac.beta` | `MacOverlay Beta` | Interview helper + beta features |
| Production | `./build.sh --channel prod` | `tech.thecloser.mac` | `MacOverlay` | Interview helper only |

Data folders live in `~/Library/Application Support/`. Only one channel
should run at a time, because they share the same global hotkeys.

**Beta features** (currently just Regular call) are flags in
`FeatureFlags.swift` set to `previewFeatures`. To ship one to production, set
its flag to `true`. Flags set to `false` are off in every build.

**Branches**
- Feature branch → pull request into `beta`. CI runs the tests and attaches
  Dev and Production builds to the pull request (the testing environment).
- `beta` → pull request into `main` when a beta is ready for everyone.

**Releases**
```bash
./package.sh --channel beta   # build/TheCloser-Beta.dmg
gh release create v3.2-beta.1 build/TheCloser-Beta.dmg --prerelease --target beta

./package.sh --channel prod   # build/TheCloser.dmg
gh release create v3.2 build/TheCloser.dmg --target main
```
Production releases must attach a file named exactly `TheCloser.dmg`: the
website's Download buttons point at `releases/latest/download/TheCloser.dmg`.
Pre-releases never count as "latest", so beta builds can't reach the website.

---

## First-run Setup

1. **Choose how to run it.** First launch offers **Bring your own keys**
   (free) or **We handle everything** (paid plans, coming soon).
2. **Add your keys.** Bring-your-own-key needs an
   [OpenRouter key](https://openrouter.ai/keys) for the AI models and an
   [ElevenLabs key](https://elevenlabs.io/app/settings/api-keys) for
   transcription; **Start interview** stays disabled until both are set.
   Change them later under **Profile → Preferences → AI**. Keys are stored
   locally in `UserDefaults`.
3. **Grant permissions when prompted:**
   - **Microphone** + **Speech Recognition** — live transcription.
   - **Screen Recording** — screenshots and system-audio capture
     (ScreenCaptureKit). Pre-warmed at launch.

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
| `⌘ ⏎` | Get the answer now, without waiting for the speaker to pause (during a live session) |
| `⌘ ⇧ ⏎` | Capture a screenshot and send it to the AI (during a live session) |
| `⌃⌥ T` | Start / stop recording |
| `⌃⌥ S` | Capture a screenshot and attach it |
| `⌃⌥ arrows` | Move the panel · `⌃⇧ arrows` resize it |
| `⌃⌥ X` | Quit thecloser completely (and relaunch it — see below) |

Hotkeys use Carbon `RegisterEventHotKey`, so they fire globally with no
Accessibility permission required. `⌘ ⏎` and `⌘ ⇧ ⏎` are registered only
while recording: a global hotkey takes the combo away from every other app,
and `⌘ ⏎` means "send" in Slack, Gmail and many others.

### Quit and relaunch with one combo

`⌃⌥ Space` only hides the window — the app keeps running. `⌃⌥ X` ends the
process outright: no window, no menu-bar item, nothing left in Activity
Monitor.

Nothing that has exited can listen for its own hotkey, so the way back has to
belong to macOS. **Preferences ▸ Shortcuts ▸ Install** writes a no-input Quick
Action to `~/Library/Services` and binds `⌃⌥ X` to it, which relaunches the
app. While thecloser is running, its own Carbon hotkey takes the keystroke
first, so the same combo quits; once the process is gone, the Quick Action
picks it up and opens the app again. The Quick Action runs only for the
instant the key is pressed — it leaves nothing resident.

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
- **Feature flags:** `FeatureFlags.swift` hides out-of-scope surfaces
  (peer-control, calendar, workspaces) without deleting the code.
- **Models:** the catalogue lives in `OverlayViewModel.availableModels`; ids
  route to the right provider in `AIManager` by prefix.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Blocked by Gatekeeper | System Settings → Privacy & Security → **Open Anyway**. |
| Overlay shows up in screen share | Should never happen — every window is `sharingType = .none`. File it if you see it. |
| No transcription | Grant Microphone + Speech Recognition; for system audio, grant Screen Recording. |
| "Add your OpenRouter and ElevenLabs keys" | Profile → Preferences → AI. Both are required to start an interview. |

---

## License

[MIT](LICENSE) — free to use and modify. The app charges nothing; bring your
own provider API key.
</content>
</invoke>
