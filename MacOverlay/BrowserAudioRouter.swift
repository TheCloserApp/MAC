import AppKit
import CoreAudio
import Foundation

/// Redirects the macOS default audio *input* device to a BlackHole virtual
/// loopback device while the user has "System" selected as the browser audio
/// source. WKWebView's `getUserMedia({ audio: true })` always reads from
/// whatever the OS reports as the default input — so the only way to feed
/// system audio into a webpage's microphone is to make the input device
/// itself contain system audio. BlackHole is the standard free driver for
/// that (https://existential.audio/blackhole).
///
/// The user is still responsible for routing system *output* into BlackHole
/// (typically via a Multi-Output Device in Audio MIDI Setup); this class only
/// flips the *input* side.
final class BrowserAudioRouter {

    static let shared = BrowserAudioRouter()

    /// Substring (case-insensitive) we match against the device name to find
    /// any BlackHole variant — 2ch, 16ch, 64ch.
    private let blackHoleNameNeedle = "blackhole"

    private var savedInputDeviceID:   AudioDeviceID?
    private var blackHoleDeviceID:    AudioDeviceID?
    private(set) var isRouting = false

    /// Fires on the main queue whenever the system output device changes so
    /// the UI can re-render the routing banner. Set by callers (e.g. the
    /// view model) once.
    var onSystemOutputStateChange: ((SystemOutputState) -> Void)?
    private var outputListenerInstalled = false

    private init() {
        // Always restore the user's original input device on app quit so we
        // never leave the system stuck on BlackHole after MacOverlay exits.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        installOutputListener()
    }

    // MARK: - Public API

    /// Switch macOS default input to BlackHole. Throws if BlackHole isn't
    /// installed or CoreAudio refuses the change.
    func enable() throws {
        if isRouting { return }

        let allInputs = inputDevices()
        let names = allInputs.map { deviceName($0) }
        NSLog("[BrowserAudioRouter] visible input devices: %@", names.description)

        guard let blackHoleID = findBlackHoleInput() else {
            NSLog("[BrowserAudioRouter] BlackHole not found among inputs.")
            throw RouterError.blackHoleMissing
        }
        NSLog("[BrowserAudioRouter] BlackHole device id=%u name=%@",
              blackHoleID, deviceName(blackHoleID))

        let currentInput = try defaultInputDeviceID()
        NSLog("[BrowserAudioRouter] current default input id=%u name=%@",
              currentInput, deviceName(currentInput))

        if currentInput == blackHoleID {
            // Someone already set BlackHole as default; treat as routed but
            // don't overwrite the saved device with itself (would block restore).
            blackHoleDeviceID = blackHoleID
            isRouting = true
            NSLog("[BrowserAudioRouter] default input already BlackHole; marking active.")
            return
        }

        try setDefaultInputDevice(blackHoleID)
        savedInputDeviceID = currentInput
        blackHoleDeviceID  = blackHoleID
        isRouting = true
        NSLog("[BrowserAudioRouter] switched default input to BlackHole.")
    }

    /// Restore the input device that was active before `enable()` ran.
    func disable() {
        guard isRouting else { return }
        if let saved = savedInputDeviceID {
            try? setDefaultInputDevice(saved)
        }
        savedInputDeviceID = nil
        blackHoleDeviceID  = nil
        isRouting = false
    }

    /// True if any BlackHole input device is currently visible to CoreAudio.
    /// Used by the UI to decide whether to show the install prompt.
    var isBlackHoleInstalled: Bool { findBlackHoleInput() != nil }

    /// Open the BlackHole download page in the user's default browser.
    static func openInstallPage() {
        if let url = URL(string: "https://existential.audio/blackhole/") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open Audio MIDI Setup so the user can build a Multi-Output Device
    /// that includes BlackHole. Falls back gracefully if the path moves on
    /// some macOS variant.
    static func openAudioMIDISetup() {
        let path = "/System/Applications/Utilities/Audio MIDI Setup.app"
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
        }
    }

    // MARK: - System output state

    /// Whether the macOS default *output* device is configured so that audio
    /// reaches BlackHole. BlackHole's input only carries signal when some
    /// app writes to its output, so when the user picks `.systemAudio` for
    /// the browser we need their system output to be either BlackHole
    /// directly or — more usefully — a Multi-Output Device that includes it.
    enum SystemOutputState {
        /// Default output is a Multi-Output Device that contains BlackHole.
        /// Audio plays through speakers AND is captured by BlackHole. Ideal.
        case routedThroughBlackHole
        /// Default output is BlackHole itself. Audio is captured but the
        /// user hears nothing through their speakers.
        case blackHoleOnly
        /// Default output is a normal device with no BlackHole routing.
        /// Anything reading BlackHole's input gets digital silence.
        case notRouted
    }

    /// Inspect the current default output device and classify it.
    func currentSystemOutputState() -> SystemOutputState {
        guard let outputID = try? defaultOutputDeviceID() else { return .notRouted }

        let outputName = deviceName(outputID).lowercased()
        if outputName.contains(blackHoleNameNeedle) {
            return .blackHoleOnly
        }

        for uid in aggregateSubDeviceUIDs(outputID) {
            if let subID = deviceID(forUID: uid),
               deviceName(subID).lowercased().contains(blackHoleNameNeedle) {
                return .routedThroughBlackHole
            }
            // Fallback: some aggregates report sub-devices we can't translate
            // back to an AudioDeviceID (e.g. unplugged / inactive). Match the
            // UID string itself, which BlackHole sets to "BlackHole2ch_UID"
            // / "BlackHole16ch_UID" / etc.
            if uid.lowercased().contains(blackHoleNameNeedle) {
                return .routedThroughBlackHole
            }
        }
        return .notRouted
    }

    // MARK: - App lifecycle

    @objc private func handleTerminate() {
        disable()
    }

    // MARK: - CoreAudio plumbing

    private func findBlackHoleInput() -> AudioDeviceID? {
        for id in inputDevices() {
            if deviceName(id).lowercased().contains(blackHoleNameNeedle) {
                return id
            }
        }
        return nil
    }

    private func inputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.filter { hasInputStreams($0) }
    }

    private func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope:    kAudioDevicePropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufList.deallocate() }

        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &dataSize, bufList) == noErr else {
            return false
        }

        let typed = bufList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(typed)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        // kAudioDevicePropertyDeviceNameCFString returns a +1 retained CFString,
        // so we receive it as Unmanaged and balance the retain ourselves.
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &unmanagedName) == noErr,
              let cfName = unmanagedName?.takeRetainedValue() else {
            return ""
        }
        return cfName as String
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw RouterError.coreAudio(status) }
        return deviceID
    }

    private func defaultOutputDeviceID() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw RouterError.coreAudio(status) }
        return deviceID
    }

    /// Returns the sub-device UID strings for an aggregate / multi-output
    /// device, or an empty array if the device isn't an aggregate.
    private func aggregateSubDeviceUIDs(_ device: AudioDeviceID) -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return [] }
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        var unmanaged: Unmanaged<CFArray>?
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &dataSize, &unmanaged) == noErr,
              let array = unmanaged?.takeRetainedValue() as? [String] else {
            return []
        }
        return array
    }

    /// Translate an audio device UID string to its current `AudioDeviceID`.
    /// Returns nil for inactive or unknown UIDs.
    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var inUID = uid as CFString
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &inUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, qualifierSize, uidPtr,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Subscribe to default-output-device changes so the UI can update the
    /// routing banner without polling. Fires once with the current state on
    /// install so callers don't have to query separately.
    private func installOutputListener() {
        guard !outputListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            let state = self.currentSystemOutputState()
            self.onSystemOutputStateChange?(state)
        }
        if status == noErr {
            outputListenerInstalled = true
        } else {
            NSLog("[BrowserAudioRouter] failed to install output listener: %d", status)
        }
    }

    private func setDefaultInputDevice(_ id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &deviceID
        )
        guard status == noErr else { throw RouterError.coreAudio(status) }
    }

    // MARK: - Errors

    enum RouterError: LocalizedError {
        case blackHoleMissing
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .blackHoleMissing:
                return "BlackHole virtual audio driver isn't installed."
            case .coreAudio(let status):
                return "CoreAudio error \(status) while switching audio input."
            }
        }
    }
}
