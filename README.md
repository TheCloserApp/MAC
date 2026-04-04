# MacOverlay — Floating Toolbar for macOS

A lightweight, native Swift overlay toolbar that **stays visible over full-screen apps**.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

---

## What It Does

MacOverlay creates a small floating toolbar that:

- ✅ **Floats over full-screen apps** (YouTube, games, presentations, etc.)
- ✅ **Visible on all Spaces / virtual desktops**
- ✅ **Draggable** — move it anywhere on screen
- ✅ **Native macOS blur** — uses vibrancy like system UI
- ✅ **Menu bar icon** — toggle visibility, reset position, quit
- ✅ **No Dock icon** — runs as a background utility

### Built-in Tools

| Button     | Action                                         |
|------------|-------------------------------------------------|
| 📷 Screenshot | Launches macOS interactive screenshot (⌘⇧4 style) |
| ⏱ Timer      | Quick 5-minute timer prompt                     |
| 📝 Note       | Quick note → saves .txt to Desktop              |
| 📌 Pin        | Toggle pinned state                             |
| ⚙ Settings    | Info / help dialog                              |

---

## How to Build & Run

### Prerequisites
- **macOS 13.0+** (Ventura or later)
- **Xcode Command Line Tools** (install with `xcode-select --install`)

### Option 1: Build Script (Recommended)

```bash
cd MacOverlay
chmod +x build.sh
./build.sh
```

Then run:
```bash
open build/MacOverlay.app
```

### Option 2: Manual Compile

```bash
cd MacOverlay/MacOverlay
swiftc -o MacOverlay \
    -framework Cocoa \
    -target arm64-apple-macos13.0 \
    main.swift AppDelegate.swift OverlayContentView.swift
./MacOverlay
```

> **Note for Intel Macs:** Change `-target arm64-apple-macos13.0` to
> `-target x86_64-apple-macos13.0` in the build script.

### Option 3: Xcode

1. Create a new macOS App project in Xcode
2. Delete the generated files
3. Add the three `.swift` files and `Info.plist`
4. Set the deployment target to macOS 13.0
5. Build & Run

---

## Install to Applications

```bash
cp -r build/MacOverlay.app /Applications/
```

### Launch at Login (optional)

1. Open **System Settings → General → Login Items**
2. Click **+** and add **MacOverlay.app**

---

## How It Works (Key Techniques)

The overlay stays on top of full-screen apps using these macOS APIs:

```swift
// 1. High window level — above most system UI
panel.level = .statusBar + 1

// 2. Collection behaviors — appear on all spaces and full-screen
panel.collectionBehavior = [
    .canJoinAllSpaces,
    .fullScreenAuxiliary,
    .stationary
]

// 3. NSPanel with non-activating style — doesn't steal focus
NSPanel(styleMask: [.nonactivatingPanel, .fullSizeContentView], ...)

// 4. Stays visible when app is not active
panel.hidesOnDeactivate = false
```

---

## Customization Ideas

- **Add more buttons**: Edit the `toolbarItems` array in `OverlayContentView.swift`
- **Change size**: Modify `panelWidth` / `panelHeight` in `AppDelegate.swift`
- **Adjust opacity**: Change the `alphaValue` in `mouseExited` for idle transparency
- **Different position**: Change the initial `x, y` calculation in `setupOverlayPanel()`
- **Keyboard shortcuts**: Add global hotkeys using `NSEvent.addGlobalMonitorForEvents`

---

## Troubleshooting

| Issue | Solution |
|-------|---------|
| App blocked by Gatekeeper | System Settings → Privacy & Security → Allow |
| Not visible over full-screen | Ensure `fullScreenAuxiliary` is in collectionBehavior |
| Steals focus from other apps | Ensure using `NSPanel` with `.nonactivatingPanel` |
| Disappears when switching Spaces | Ensure `.canJoinAllSpaces` is set |

---

## License

MIT — Use freely, modify as you like.
