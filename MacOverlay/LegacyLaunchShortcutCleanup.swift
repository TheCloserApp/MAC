import Foundation

/// Removes the "Launch thecloser" Quick Action that v3.1 could install in
/// ~/Library/Services to relaunch the app with ⌃⌥X. The feature is gone,
/// but an installed copy would keep launching the app on its own until
/// it's deleted.
enum LegacyLaunchShortcutCleanup {
    private static let serviceNames = ["Launch thecloser", "Launch thecloser Dev", "Launch thecloser Beta"]

    /// Cheap no-op when nothing is installed. Call off the main thread:
    /// it may run `pbs`.
    static func removeIfInstalled() {
        let fm = FileManager.default
        let services = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services", isDirectory: true)
        var removedAny = false
        for name in serviceNames {
            let url = services.appendingPathComponent("\(name).workflow", isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removeKeyEquivalent(serviceName: name)
                removedAny = true
                NSLog("[LegacyLaunchShortcutCleanup] removed %@", url.path)
            } catch {
                NSLog("[LegacyLaunchShortcutCleanup] could not remove %@: %@", url.path, error.localizedDescription)
            }
        }
        if removedAny { refreshServices() }
    }

    /// pbs keeps the ⌃⌥X binding under "(null) - <service> - runWorkflowAsService".
    private static func removeKeyEquivalent(serviceName: String) {
        guard var status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString,
                                                     "pbs" as CFString) as? [String: Any] else { return }
        status.removeValue(forKey: "(null) - \(serviceName) - runWorkflowAsService")
        CFPreferencesSetAppValue("NSServicesStatus" as CFString, status as CFPropertyList, "pbs" as CFString)
        CFPreferencesAppSynchronize("pbs" as CFString)
    }

    private static func refreshServices() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        task.arguments = ["-update"]
        try? task.run()
    }
}
