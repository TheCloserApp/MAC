import AppKit
import Foundation

/// Installs a system-level Quick Action so the quit hotkey can also bring
/// thecloser *back* after the app has fully exited.
///
/// Why this has to live outside the app: ⌃⌥X quits for real — the process
/// is gone, nothing of ours stays resident, and nothing shows up in Activity
/// Monitor. But a process that no longer exists cannot listen for its own
/// relaunch hotkey, so the "open it again" half of the shortcut has to be
/// owned by macOS itself. A no-input Services Quick Action does exactly
/// that: it's a plist bundle in ~/Library/Services, macOS routes the key
/// equivalent to it, and the shell step only runs for the instant the key
/// is pressed.
///
/// While the app IS running, its Carbon hotkey intercepts ⌃⌥X before the
/// frontmost app's responder chain ever sees the keystroke, so the service
/// doesn't fire — the same combo means "quit" when running and "launch"
/// when not. The installed script toggles in both directions anyway, so a
/// race can never end up with two copies running.
enum LaunchShortcutInstaller {

    // MARK: - Identity

    /// Name shown in the Services menu and in System Settings ▸ Keyboard
    /// Shortcuts ▸ Services. Also part of the pbs preference key, so
    /// renaming it orphans any previously registered key equivalent.
    static let serviceName = "Launch thecloser" + AppChannel.current.nameSuffix

    /// AppKit key-equivalent syntax: ^ = control, ~ = option. Matches the
    /// in-app `HotkeyAction.quitApp` binding so one combo does both halves.
    static let keyEquivalent = "^~x"

    /// Human-readable form of `keyEquivalent`, for UI copy.
    static let displayShortcut = "⌃⌥X"

    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "tech.thecloser.mac"

    /// pbs stores per-service settings under "<provider bundle id> - <service
    /// name> - <NSMessage>". Workflow services have no provider bundle, so
    /// the first field is the literal string "(null)".
    private static var servicesStatusKey: String {
        "(null) - \(serviceName) - runWorkflowAsService"
    }

    private static var executableName: String {
        Bundle.main.executableURL?.lastPathComponent ?? "thecloser"
    }

    // MARK: - Locations

    static var serviceURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
            .appendingPathComponent("\(serviceName).workflow", isDirectory: true)
    }

    /// True once the workflow bundle exists AND pbs knows about the key
    /// equivalent. Either half missing means the shortcut won't fire, so
    /// both are required before we tell the user it's installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: serviceURL.path) && registeredKeyEquivalent != nil
    }

    private static var registeredKeyEquivalent: String? {
        let status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString,
                                               "pbs" as CFString) as? [String: Any]
        let entry = status?[servicesStatusKey] as? [String: Any]
        return entry?["key_equivalent"] as? String
    }

    // MARK: - Install / uninstall

    static func install() throws {
        let fm = FileManager.default
        let contents = serviceURL.appendingPathComponent("Contents", isDirectory: true)

        if fm.fileExists(atPath: serviceURL.path) {
            try fm.removeItem(at: serviceURL)
        }
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)

        try writePlist(infoPlist(), to: contents.appendingPathComponent("Info.plist"))
        try writePlist(workflowPlist(script: toggleScript(appPath: Bundle.main.bundleURL.path)),
                       to: contents.appendingPathComponent("document.wflow"))

        try registerKeyEquivalent()
        refreshServices()
    }

    static func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: serviceURL.path) {
            try fm.removeItem(at: serviceURL)
        }
        removeKeyEquivalent()
        refreshServices()
    }

    /// System Settings ▸ Keyboard. macOS occasionally needs the Services
    /// list opened once before a freshly registered key equivalent starts
    /// firing, so the UI offers this as a follow-up step.
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - pbs registration

    private static func registerKeyEquivalent() throws {
        var status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString,
                                               "pbs" as CFString) as? [String: Any] ?? [:]
        status[servicesStatusKey] = [
            "enabled_context_menu": 1,
            "enabled_services_menu": 1,
            "key_equivalent": keyEquivalent,
        ]
        CFPreferencesSetAppValue("NSServicesStatus" as CFString,
                                 status as CFPropertyList,
                                 "pbs" as CFString)
        guard CFPreferencesAppSynchronize("pbs" as CFString) else {
            throw LaunchShortcutError.preferencesWriteFailed
        }
    }

    private static func removeKeyEquivalent() {
        guard var status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString,
                                                     "pbs" as CFString) as? [String: Any] else { return }
        status.removeValue(forKey: servicesStatusKey)
        CFPreferencesSetAppValue("NSServicesStatus" as CFString,
                                 status as CFPropertyList,
                                 "pbs" as CFString)
        CFPreferencesAppSynchronize("pbs" as CFString)
    }

    /// Ask the pasteboard server to re-scan ~/Library/Services and reload
    /// key equivalents. Without this the new Quick Action doesn't appear
    /// until the next login. Failures are non-fatal — the service still
    /// registers itself eventually.
    private static func refreshServices() {
        for argument in ["-update", "-flush"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            task.arguments = [argument]
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: - Bundle contents

    /// A Services entry with empty send types is a "no input" Quick Action:
    /// available in every app regardless of what's selected, which is what
    /// makes it usable as a plain global keyboard shortcut.
    private static func infoPlist() -> [String: Any] {
        [
            "NSServices": [[
                "NSMenuItem": ["default": serviceName],
                "NSMessage": "runWorkflowAsService",
                "NSSendFileTypes": [],
                "NSSendTypes": [],
            ]]
        ]
    }

    private static func toggleScript(appPath: String) -> String {
        let app = appPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        # thecloser launch shortcut. Press \(displayShortcut) to bring the app
        # back after quitting it. Quits it too, as a fallback for the rare case
        # where the app's own hotkey didn't get the keystroke first.
        APP="\(app)"
        if /usr/bin/pgrep -x "\(executableName)" >/dev/null 2>&1; then
            /usr/bin/pkill -x "\(executableName)"
        elif [ -d "$APP" ]; then
            /usr/bin/open "$APP"
        else
            /usr/bin/open -b "\(bundleIdentifier)"
        fi
        """
    }

    /// Hand-rolled equivalent of what Automator saves for a single
    /// "Run Shell Script" action in a no-input Quick Action. Built as a
    /// dictionary rather than templated XML so the script body can contain
    /// quotes without any escaping games.
    private static func workflowPlist(script: String) -> [String: Any] {
        let actionBundle = "/System/Library/Automator/Run Shell Script.action"
        let action: [String: Any] = [
            "AMAccepts": [
                "Container": "List",
                "Optional": true,
                "Types": ["com.apple.cocoa.string"],
            ],
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": [
                "COMMAND_STRING": [:],
                "CheckedForUserDefaultShell": [:],
                "inputMethod": [:],
                "shell": [:],
                "source": [:],
            ],
            "AMProvides": [
                "Container": "List",
                "Types": ["com.apple.cocoa.string"],
            ],
            "ActionBundlePath": actionBundle,
            "ActionName": "Run Shell Script",
            "ActionParameters": [
                "COMMAND_STRING": script,
                "CheckedForUserDefaultShell": true,
                "inputMethod": 0,
                "shell": "/bin/zsh",
                "source": "",
            ],
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": false,
            "CanShowWhenRun": true,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": UUID().uuidString,
            "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
            "OutputUUID": UUID().uuidString,
            "UUID": UUID().uuidString,
            "UnlocalizedApplications": ["Automator"],
            "arguments": [:],
            "isViewVisible": 1,
            "location": "309.000000:253.000000",
            "nibPath": "\(actionBundle)/Contents/Resources/Base.lproj/main.nib",
        ]

        return [
            "AMApplicationBuild": "521",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [["action": action, "isViewVisible": 1]],
            "connectors": [:],
            "workflowMetaData": [
                "applicationBundleIDsByPath": [:],
                "applicationPaths": [],
                "inputTypeIdentifier": "com.apple.Automator.nothing",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 11,
                "processesInput": 0,
                "serviceInputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": 0,
                "useAutomaticInputType": 0,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ],
        ]
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

enum LaunchShortcutError: LocalizedError {
    case preferencesWriteFailed

    var errorDescription: String? {
        switch self {
        case .preferencesWriteFailed:
            return "Couldn't save the shortcut to the system Services settings."
        }
    }
}
