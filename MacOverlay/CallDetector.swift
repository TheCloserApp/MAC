import CoreAudio
import Foundation

/// Notices when a call app (Zoom, Teams, Google Meet in a browser, FaceTime,
/// …) starts using the microphone, so the overlay can offer to start an
/// interview.
///
/// Asks Core Audio which processes currently capture input. No audio is
/// read and no permission is needed. Needs macOS 14.2 (per-process audio
/// objects); on older systems it stays silent.
final class CallDetector {
    /// Called on the main queue with the call app's display name when a
    /// call starts, and nil when it ends.
    var onChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "CallDetector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state = CallState()

    func start() {
        guard #available(macOS 14.2, *) else {
            NSLog("[CallDetector] unavailable: needs macOS 14.2")
            return
        }
        guard timer == nil else { return }
        NSLog("[CallDetector] started")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in self?.state = CallState() }
        DispatchQueue.main.async { [weak self] in self?.onChange?(nil) }
    }

    private func poll() {
        guard #available(macOS 14.2, *) else { return }
        guard state.update(micApp: Self.callAppUsingMicrophone(), now: Date()) else { return }
        let app = state.current
        NSLog("[CallDetector] call app now: %@", app ?? "none")
        DispatchQueue.main.async { [weak self] in self?.onChange?(app) }
    }

    // MARK: - Which apps count as a call

    /// Bundle-id prefixes whose microphone use means "on a call". Browsers
    /// count because Google Meet, Teams on the web and most interview
    /// platforms run there. Siri, dictation and this app are deliberately
    /// absent.
    static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom.",                   "Zoom"),
        ("com.microsoft.teams",        "Microsoft Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark",        "Webex"),
        ("com.tinyspeck.slackmacgap",  "Slack"),
        ("com.apple.FaceTime",         "FaceTime"),
        ("com.hnc.Discord",            "Discord"),
        ("com.skype.skype",            "Skype"),
        ("net.whatsapp.WhatsApp",      "WhatsApp"),
        ("com.google.Chrome",          "Chrome"),
        ("com.apple.Safari",           "Safari"),
        ("com.apple.WebKit",           "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac",      "Edge"),
        ("com.brave.Browser",          "Brave"),
        ("org.mozilla.firefox",        "Firefox"),
        ("com.operasoftware.Opera",    "Opera"),
        ("com.vivaldi.Vivaldi",        "Vivaldi"),
    ]

    static func callAppName(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return callApps.first { bundleID.hasPrefix($0.prefix) }?.name
    }

    // MARK: - Core Audio

    @available(macOS 14.2, *)
    static func callAppUsingMicrophone() -> String? {
        for process in audioProcesses() where isCapturingInput(process) {
            if let name = callAppName(bundleID: bundleID(of: process)) { return name }
        }
        return nil
    }

    @available(macOS 14.2, *)
    private static func audioProcesses() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func isCapturingInput(_ process: AudioObjectID) -> Bool {
        var address = globalAddress(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Turns raw "which call app has the mic right now" polls into call start
/// and end events.
///
/// A call only ends after the mic has been free for `endGracePeriod`.
/// Muting in Google Meet can release the mic; without the grace period the
/// menu-bar icon would reappear mid-call (possibly mid screen share) and
/// the prompt would ask again on unmute.
struct CallState {
    let endGracePeriod: TimeInterval
    private(set) var current: String?
    private var lastSeen: Date?

    init(endGracePeriod: TimeInterval = 90) {
        self.endGracePeriod = endGracePeriod
    }

    /// Feeds one poll result. Returns true when `current` changed.
    mutating func update(micApp: String?, now: Date) -> Bool {
        if let micApp {
            lastSeen = now
            guard micApp != current else { return false }
            current = micApp
            return true
        }
        guard current != nil, let lastSeen, now.timeIntervalSince(lastSeen) >= endGracePeriod else { return false }
        current = nil
        self.lastSeen = nil
        return true
    }
}
