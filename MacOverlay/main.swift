import Cocoa

// Install / remove the ⌃⌥X launch Quick Action without starting the UI.
// Preferences ▸ Shortcuts has the same buttons, but that's only reachable
// while the app is running — and the whole point of this shortcut is to
// bring the app back when it isn't. So it has to work from a terminal too.
if CommandLine.arguments.contains("--install-launch-shortcut") {
    do {
        try LaunchShortcutInstaller.install()
        print("Installed “\(LaunchShortcutInstaller.serviceName)” — press \(LaunchShortcutInstaller.displayShortcut) to launch thecloser.")
        print("If nothing happens, open System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services and confirm it's checked.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Install failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--uninstall-launch-shortcut") {
    do {
        try LaunchShortcutInstaller.uninstall()
        print("Removed “\(LaunchShortcutInstaller.serviceName)”.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Uninstall failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
