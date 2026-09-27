import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Shared microphone plumbing: device diagnostics, an engine-start path
/// that survives the input device being renegotiated underneath us, and a
/// watchdog for the case where the tap installs cleanly but no audio ever
/// arrives.
///
/// Why this exists: the input device is a SHARED, renegotiable resource.
/// The moment another app starts a call (WhatsApp, FaceTime, Zoom, Meet)
/// macOS can
///
///   * switch the default input — a Bluetooth headset flips from A2DP to
///     the mono HFP mic, which is a *different* CoreAudio device;
///   * change the device's nominal sample rate — voice-processing clients
///     run the hardware at their own rate and every other client has to
///     follow;
///   * leave the device unusable for a few hundred milliseconds while it
///     reconfigures.
///
/// In that window `inputNode.outputFormat` reports 0 Hz / 0 channels,
/// `engine.start()` throws, or — worst of all — everything succeeds and
/// the tap simply never fires. The old code treated the first two as
/// fatal ("No audio input available") and had no detection at all for the
/// third, which is why transcription "just didn't work" while a call was
/// up and started working again once the call ended.
enum MicInput {

    // MARK: - Device diagnostics

    struct Snapshot {
        var deviceID:           AudioDeviceID
        var name:               String
        var sampleRate:         Double
        /// PID holding exclusive ("hog") mode on the device, or -1 when
        /// the device is shared normally.
        var hogOwnerPID:        pid_t
        var hogOwnerName:       String?
        /// The device is running for *some* process — us or someone else.
        var isRunningSomewhere: Bool
        var isAlive:            Bool

        var logLine: String {
            "device=\"\(name)\" id=\(deviceID) rate=\(Int(sampleRate)) alive=\(isAlive) " +
            "runningSomewhere=\(isRunningSomewhere) hog=\(hogOwnerName ?? String(hogOwnerPID))"
        }
    }

    static func snapshot() -> Snapshot {
        let dev = defaultInputDevice()
        let hogPID = hogOwner(dev)
        return Snapshot(
            deviceID:           dev,
            name:               deviceName(dev),
            sampleRate:         nominalSampleRate(dev) ?? 0,
            hogOwnerPID:        hogPID,
            hogOwnerName:       hogPID > 0
                ? NSRunningApplication(processIdentifier: hogPID)?.localizedName
                : nil,
            isRunningSomewhere: (u32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0,
            isAlive:            (u32(dev, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
        )
    }

    /// One-line, user-facing explanation of the most likely reason the mic
    /// isn't producing audio right now. Appended to error messages so the
    /// user gets something actionable instead of "no audio input".
    static func troubleHint() -> String {
        let s = snapshot()
        if s.hogOwnerPID > 0, s.hogOwnerPID != ProcessInfo.processInfo.processIdentifier {
            let who = s.hogOwnerName ?? "another app (pid \(s.hogOwnerPID))"
            return "“\(who)” has taken exclusive control of “\(s.name)”. End its call or quit it, then try again."
        }
        if !s.isAlive {
            return "The input device “\(s.name)” is no longer available. Pick a working mic in System Settings → Sound → Input."
        }
        if s.isRunningSomewhere {
            return "“\(s.name)” is currently in use by another app — a call in WhatsApp, FaceTime, Zoom, etc. " +
                   "End the call, or switch TheCloser to System audio, or pick a different input in System Settings → Sound → Input."
        }
        return "Current input: “\(s.name)”. Check System Settings → Sound → Input and that TheCloser has Microphone permission."
    }

    // MARK: - Engine start (retrying, with a voice-processing fallback)

    struct Started {
        let engine: AVAudioEngine
        let format: AVAudioFormat
        /// True when the plain input unit failed and we fell back to the
        /// voice-processing (echo-cancelling) one.
        let usedVoiceProcessing: Bool
    }

    enum Failure: LocalizedError {
        case noUsableInput(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noUsableInput(let hint):     return "No microphone audio. \(hint)"
            case .engineStartFailed(let hint): return "Couldn't open the microphone. \(hint)"
            }
        }
    }

    /// Delays between attempts. Device reconfiguration triggered by another
    /// app grabbing the mic settles well inside 2s, so a handful of spaced
    /// retries turns a hard failure into a short pause.
    private static let retryDelays: [TimeInterval] = [0, 0.2, 0.4, 0.7, 1.0]

    /// Build a fresh `AVAudioEngine`, resolve a usable input format, let the
    /// caller install its tap, and start — retrying through transient
    /// reconfiguration. If every plain attempt fails (and the caller didn't
    /// already ask for it) one final attempt enables the voice-processing
    /// input unit: a VP client coexists with the VP clients that call apps
    /// install, where a plain tap is the combination that ends up silent.
    ///
    /// A fresh engine per attempt is deliberate — an `AVAudioEngine` whose
    /// input node resolved against a device that has since changed will
    /// happily re-tap and then deliver nothing.
    static func startEngine(label: String,
                            voiceProcessing: Bool = false,
                            installTap: (AVAudioEngine, AVAudioFormat) throws -> Void) async throws -> Started {
        NSLog("[%@] mic pre-flight: %@", label, snapshot().logLine)

        var lastError: Error?
        var attemptsVP = voiceProcessing

        for (index, delay) in retryDelays.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do {
                let started = try attemptStart(label: label,
                                               attempt: index + 1,
                                               voiceProcessing: attemptsVP,
                                               installTap: installTap)
                return started
            } catch {
                lastError = error
            }
        }

        // Last resort: the echo-cancelling input unit.
        if !attemptsVP {
            attemptsVP = true
            NSLog("[%@] plain input failed %d times — retrying with voice processing enabled",
                  label, retryDelays.count)
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let started = try? attemptStart(label: label,
                                               attempt: retryDelays.count + 1,
                                               voiceProcessing: true,
                                               installTap: installTap) {
                return started
            }
        }

        let hint = troubleHint()
        NSLog("[%@] mic start gave up: %@ | %@",
              label, lastError?.localizedDescription ?? "no usable input format", hint)
        if let lastError, !(lastError is Failure) {
            throw Failure.engineStartFailed("\(lastError.localizedDescription) \(hint)")
        }
        throw Failure.noUsableInput(hint)
    }

    private static func attemptStart(label: String,
                                     attempt: Int,
                                     voiceProcessing: Bool,
                                     installTap: (AVAudioEngine, AVAudioFormat) throws -> Void) throws -> Started {
        let engine = AVAudioEngine()
        let node   = engine.inputNode

        if voiceProcessing {
            // Must be set before the engine starts; it swaps in the VPIO
            // unit and re-resolves the node's format.
            do { try node.setVoiceProcessingEnabled(true) }
            catch { NSLog("[%@] setVoiceProcessingEnabled failed: %@", label, error.localizedDescription) }
        }

        let format = node.outputFormat(forBus: 0)
        NSLog("[%@] attempt %d: input format channels=%u rate=%.0f vp=%@",
              label, attempt, format.channelCount, format.sampleRate, voiceProcessing ? "yes" : "no")

        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw Failure.noUsableInput("The input device is reconfiguring.")
        }

        do {
            try installTap(engine, format)
            engine.prepare()
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            NSLog("[%@] attempt %d failed: %@", label, attempt, error.localizedDescription)
            throw error
        }

        NSLog("[%@] engine started (vp=%@)", label, voiceProcessing ? "yes" : "no")
        return Started(engine: engine, format: format, usedVoiceProcessing: voiceProcessing)
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope:    scope,
                                   mElement:  kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var id   = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var addr = address(kAudioDevicePropertyDeviceNameCFString)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var unmanaged: Unmanaged<CFString>?
        // Returns a +1 retained CFString — take ownership so it isn't leaked.
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &unmanaged) == noErr,
              let name = unmanaged?.takeRetainedValue() else { return "Unknown input" }
        return name as String
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private static func hogOwner(_ device: AudioDeviceID) -> pid_t {
        var addr  = address(kAudioDevicePropertyHogMode, kAudioDevicePropertyScopeInput)
        var owner = pid_t(-1)
        var size  = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &owner) == noErr else { return -1 }
        return owner
    }

    private static func u32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr  = address(selector)
        var value = UInt32(0)
        var size  = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Default-input-device monitoring

    /// Fires when the *system* default input device changes — a Bluetooth
    /// headset flipping into call (HFP) mode is a device swap, not a format
    /// change, and `AVAudioEngineConfigurationChange` doesn't always land
    /// for it. Whoever is capturing needs to rebuild against the new device
    /// or it sits deaf for the rest of the call.
    final class DeviceMonitor {
        private var listener: AudioObjectPropertyListenerBlock?
        private var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        /// - Parameter onChange: called on the main queue.
        func start(onChange: @escaping () -> Void) {
            stop()
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            listener = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }

        func stop() {
            guard let listener else { return }
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, listener)
            self.listener = nil
        }

        deinit { stop() }
    }
}

// MARK: - Flow watchdog

/// Detects a microphone tap that installed successfully but isn't actually
/// delivering audio — the failure mode that made the app look like it was
/// listening while a call app held the input device. Three cases:
///
///  * **no buffers at all** within a few seconds of start;
///  * **buffers stopped** arriving mid-session;
///  * **buffers arriving but digital silence** — a real mic always has a
///    noise floor, so a stream that never crosses it is a dead input, not
///    a quiet room.
///
/// Fires `onStall` at most once per `noteStart()`; the owner restarts
/// capture, which re-arms it.
final class MicFlowWatchdog {

    private let label:   String
    private let onStall: (String) -> Void

    private var timer: DispatchSourceTimer?

    /// Guards the counters — the tap runs on the audio render thread while
    /// the timer reads on main.
    private let lock = NSLock()
    private var startedAt    = Date.distantPast
    private var bufferCount  = 0
    private var lastBufferAt = Date.distantPast
    private var sawSignal    = false
    private var reported     = false

    /// Seconds of nothing-at-all after start before we call it dead.
    private let startGrace:   TimeInterval = 3.0
    /// Seconds without a buffer mid-session before we call it dead.
    private let stallTimeout: TimeInterval = 2.5
    /// Seconds of unbroken digital silence before we call the input dead.
    /// Deliberately long: this is the backstop for a stream that is being
    /// delivered but zeroed, and a false positive costs a capture restart.
    private let silenceLimit: TimeInterval = 15.0
    /// Anything above this counts as signal. -80 dBFS sits below any real
    /// ADC's noise floor but far above the exact zeros a dead/muted stream
    /// delivers, so a genuinely quiet room never trips it.
    private let noiseFloor: Float = 0.0001

    init(label: String, onStall: @escaping (String) -> Void) {
        self.label   = label
        self.onStall = onStall
    }

    /// Arm (or re-arm) the watchdog. Call right after the engine starts.
    func noteStart() {
        lock.lock()
        startedAt    = Date()
        bufferCount  = 0
        lastBufferAt = .distantPast
        sawSignal    = false
        reported     = false
        lock.unlock()

        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Called from the audio thread for every captured buffer.
    func note(_ buffer: AVAudioPCMBuffer) {
        let peak = MicFlowWatchdog.peak(of: buffer)
        let now  = Date()
        lock.lock()
        bufferCount  += 1
        lastBufferAt  = now
        if peak > noiseFloor { sawSignal = true }
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let started  = startedAt
        let count    = bufferCount
        let last     = lastBufferAt
        let signal   = sawSignal
        let already  = reported
        lock.unlock()
        guard !already else { return }

        let elapsed = Date().timeIntervalSince(started)
        let reason: String?
        if count == 0 {
            reason = elapsed > startGrace
                ? "no audio arrived from the microphone" : nil
        } else if Date().timeIntervalSince(last) > stallTimeout {
            reason = "microphone audio stopped"
        } else if !signal && elapsed > silenceLimit {
            reason = "the microphone is only delivering silence"
        } else {
            reason = nil
        }

        guard let reason else { return }
        lock.lock(); reported = true; lock.unlock()
        stop()
        NSLog("[%@] mic flow watchdog: %@ (%.1fs, %d buffers)", label, reason, elapsed, count)
        onStall(reason)
    }

    /// Coarse peak over every 32nd sample — enough to separate "signal" from
    /// "digital silence" without costing anything on the render thread.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let data = buffer.floatChannelData?[0] {
            var peak: Float = 0
            var i = 0
            while i < n {
                let v = abs(data[i])
                if v > peak { peak = v }
                i += 32
            }
            return peak
        }
        if let data = buffer.int16ChannelData?[0] {
            var peak: Int16 = 0
            var i = 0
            while i < n {
                let v = abs(data[i])
                if v > peak { peak = v }
                i += 32
            }
            return Float(peak) / 32767.0
        }
        return 0
    }
}
