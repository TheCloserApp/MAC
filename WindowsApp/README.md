# thecloser — Invisible AI Copilot for Windows

The Windows port of [thecloser](../README.md): a **pure-Rust** overlay that
floats above every app — including full-screen calls — and is **excluded from
screen capture**, so it's there for you but never shows up in a screen share or
recording. Built as a real-time **interview / meeting copilot**: it listens,
transcribes the other side, and streams answers you can read while you talk.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-blue)
![Rust](https://img.shields.io/badge/Rust-stable-orange)
![egui](https://img.shields.io/badge/UI-egui%2Feframe-purple)

---

## What It Does

- 🫥 **Invisible to screen sharing** — the window is marked
  `WDA_EXCLUDEFROMCAPTURE` via `SetWindowDisplayAffinity`, so Zoom / Meet /
  Teams / OBS / Game Bar capture the screen *without* the overlay. No taskbar
  icon and not in Alt-Tab either (`WS_EX_TOOLWINDOW`).
- 🎧 **Live transcription** — captures **system audio** (WASAPI loopback — i.e.
  the interviewer through your speakers) or your **mic**, runs an energy VAD to
  slice it into utterances, and transcribes each via OpenAI Whisper or
  ElevenLabs Scribe.
- 🤖 **Streaming AI answers** — pipes the live transcript to the model and
  streams a reply formatted for instant scanning. Interview mode leads with a
  verbatim opening line plus a few tight bullets.
- 🪟 **Floats everywhere** — borderless, translucent, always-on-top. Drag the
  brand to move; resize from the edges or with hotkeys.
- 🧠 **Multi-provider** — one picker across Anthropic, OpenAI, Kimi (Moonshot),
  Grok (xAI), DeepSeek, NVIDIA NIM, and OpenRouter. Bring your own keys.
- ⌨️ **Global hotkeys** — toggle, record, push-to-talk Quick Ask,
  explain-clipboard, move/resize — all fire regardless of the focused app.

### Session modes

| Mode | Use |
|------|-----|
| **Interview** | Live interview copilot — verbatim opening line + scannable bullets, grounded in your résumé/JD context. |
| **Meeting**   | Summaries, action items, decisions, and suggested questions. |
| **Call**      | Real-time assist on a regular call. |
| **General**   | A concise floating assistant for anything else. |

---

## Architecture

A two-crate Cargo workspace:

```
WindowsApp/
├── copilot-core/        # portable logic — no OS/GUI deps, unit-tested on any host
│   └── src/
│       ├── models.rs    # model catalogue + provider routing  (← AIManager)
│       ├── modes.rs     # session modes + system prompts       (← SessionMode)
│       ├── prompt.rs    # {NAME}/{ROLE}/{COMPANY} + context anchor
│       ├── filter.rs    # transcript noise/filler heuristics   (← TranscriptFilter)
│       ├── vad.rs        # energy voice-activity segmenter
│       ├── ai.rs        # multi-provider streaming client       (← AIManager)
│       └── settings.rs  # JSON-backed config
└── thecloser/           # the eframe (egui) app
    └── src/
        ├── main.rs      # window setup (borderless, transparent, on-top)
        ├── app.rs       # egui UI + per-frame wiring, auto-send flow
        ├── backend.rs   # Tokio runtime + channels (UI never blocks)
        ├── audio.rs     # WASAPI capture/loopback → VAD utterances  [Windows]
        ├── transcribe.rs# Whisper / Scribe STT for one utterance
        ├── hotkeys.rs   # global shortcuts
        └── overlay.rs   # SetWindowDisplayAffinity capture-exclusion [Windows]
```

The split is deliberate: `copilot-core` is OS-independent and fully unit-tested
(`cargo test -p copilot-core`), while the Windows-only OS integration
(capture-exclusion, WASAPI) is isolated behind `#[cfg(windows)]` so the rest of
the app still builds and runs on macOS/Linux for UI development.

---

## Build & Run (on Windows)

### Prerequisites
- **Windows 10 2004+ or Windows 11** (older builds run, but the
  capture-exclusion affinity needs 2004+).
- **[Rust](https://rustup.rs)** (stable, MSVC toolchain).
- WebView2 / extra runtimes are **not** needed — it's a single native binary.

### Build
```powershell
cd WindowsApp
cargo run --release            # build + launch
# or
cargo build --release          # binary at target\release\thecloser.exe
```

### Test the portable core (any OS)
```bash
cargo test -p copilot-core
```

---

## First-run Setup

1. **Add an API key.** Open the panel → **⚙ Settings → AI provider keys**, and
   paste a key for any provider you want. Keys are stored locally in
   `%APPDATA%\thecloser\config.json`.
2. **Pick a transcription engine.** Settings → Transcription. **OpenAI Whisper**
   reuses your OpenAI key; **ElevenLabs Scribe** needs an ElevenLabs key.
3. **Choose the audio source.** *System audio* captures the interviewer through
   your speakers (the usual choice); *Microphone* captures you.
4. Windows may prompt for **microphone** access on first mic capture. Loopback
   (system audio) needs no special permission.

---

## Controls

- **Open / collapse:** click the brand pill.
- **Move:** drag the brand, or `Ctrl+Alt + arrows`.
- **Resize:** drag the window edge, or `Ctrl+Shift + arrows`.

### Global hotkeys

| Shortcut | Action |
|----------|--------|
| `Ctrl+Alt+Space` | Collapse / expand the overlay |
| `Ctrl+Alt+T` | Start / stop recording |
| `Ctrl+Alt+Q` (hold) | Quick Ask by voice — record while held, sends on release |
| `Ctrl+Alt+C` | Explain whatever's on the clipboard |
| `Ctrl+Alt + arrows` | Move the panel |
| `Ctrl+Shift + arrows` | Resize the panel |

---

## How It Stays Invisible & On Top

```rust
// The core trick — excluded from screen capture (DWM omits it from any grab).
SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

// Plus a tool window so it's out of the taskbar and Alt-Tab.
ex_style |= WS_EX_TOOLWINDOW;  ex_style &= !WS_EX_APPWINDOW;
```

The window itself is created borderless, transparent, always-on-top, and with
no taskbar entry via egui's `ViewportBuilder`. See [overlay.rs](thecloser/src/overlay.rs).

---

## Notes & Limitations

- **System-audio transcription** relies on WASAPI loopback with auto-format
  conversion to 16 kHz mono; on the rare device that rejects auto-conversion,
  switch the audio source to *Microphone* or transcription falls silent.
- This is the **Windows** sibling of the macOS app; résumé tailoring, the
  browser panel, peer control, and calendar (feature-flagged off even on macOS)
  are out of scope here. The copilot core — transcribe → stream answer — is the
  focus.
- On macOS/Linux the app still compiles and the UI runs for development, but
  audio capture and screen-capture exclusion are Windows-only.

## License

[MIT](../LICENSE) — free to use and modify. The app charges nothing; bring your
own provider API key.
