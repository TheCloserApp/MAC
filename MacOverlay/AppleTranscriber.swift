import Speech
import AVFoundation
import ScreenCaptureKit
import Foundation

/// Continuous on-device transcription via Apple SFSpeechRecognizer.
/// Mirrors `TranscriptionManager`'s callback API so the VM can swap between
/// them at runtime based on whether the user has configured an ElevenLabs key.
///
/// Used as an automatic fallback when `elevenLabsAPIKey` is empty — Interview
/// and recording modes continue to work without any external API setup.
/// `@unchecked Sendable`: callbacks hop between the audio render thread,
/// Speech framework queues, and main — but every mutation of shared state
/// is funnelled through the main queue, which is the invariant the
/// compiler can't see (hence "unchecked").
final class AppleTranscriber: NSObject, @unchecked Sendable {

    // MARK: - Public API (mirrors TranscriptionManager)

    var onUpdate:  ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onCommit:  ((String) -> Void)?
    var onSilence: (() -> Void)?
    /// Engine failures. When unset, errors fall back to `onUpdate`
    /// (legacy behaviour) — but consumers should set this so error
    /// strings never masquerade as transcript text.
    var onError:   ((String) -> Void)?
    /// Audio capture died underneath us (input device disconnected,
    /// system-audio stream stopped). The owner should restart capture.
    var onCaptureInterrupted: (() -> Void)?

    private(set) var isRunning = false

    // MARK: - Private

    private var audioEngine  = AVAudioEngine()
    private var request:       SFSpeechAudioBufferRecognitionRequest?
    private var task:          SFSpeechRecognitionTask?
    private var recognizer:    SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)
    private var engineObserver: NSObjectProtocol?
    private let deviceMonitor = MicInput.DeviceMonitor()

    /// Detects a tap that installed but never delivered — see MicInput.swift.
    /// Distinct from the dead-ENGINE watchdog below: this one catches "no
    /// audio at all", that one catches "audio but no recognition results".
    private var flowWatchdog: MicFlowWatchdog?
    private var deadCaptureStreak     = 0
    private var preferVoiceProcessing = false
    private var lastStallAt           = Date.distantPast
    /// Set once any mic audio has been captured this run — lets callers
    /// tell "you said nothing" apart from "the mic never opened".
    private(set) var receivedAudio = false

    private var scStream:           SCStream?
    private var systemAudioHandler: AppleSystemAudioHandler?

    // MARK: Dead-engine watchdog state
    //
    // On-device recognition on macOS sometimes produces NOTHING even when
    // `supportsOnDeviceRecognition` is true (model still downloading,
    // stale asset, OS bug). The user experience was "I started the
    // interview, spoke for ages, and no transcript appeared". The
    // watchdog detects speech-level audio flowing into a task that has
    // produced zero results and recovers automatically.

    /// Last time audio with speech-level energy hit the engine
    /// (main-thread mirror, written via throttled dispatch from the
    /// capture threads).
    private var lastVoiceAt = Date.distantPast
    /// Throttles main-queue dispatches from the capture threads. Locked
    /// because mic taps and system-audio callbacks arrive on different
    /// threads.
    private var lastVoiceNoteAt = Date.distantPast
    private let voiceNoteLock = NSLock()
    /// True once the CURRENT recognition task has produced any result.
    private var hasResultSinceInstall = false
    /// Whether the current task runs on-device — tells the watchdog which
    /// recovery applies.
    private var currentTaskOnDevice = false
    /// Flipped when on-device recognition proves dead: every later task
    /// this run goes server-side. In-memory on purpose — retrying
    /// on-device next launch self-heals once the local model is ready.
    private var preferServerRecognition = false
    /// One free dead-task retry (server path) before telling the user.
    private var deadTaskRetried   = false
    private var deadEngineReported = false

    private var currentText       = ""
    /// Text recognized by PREVIOUS recognition tasks in this run. A single
    /// SFSpeech request degrades (and server-backed ones get killed) after
    /// roughly a minute of continuous audio, so we roll to a fresh request
    /// periodically (see refreshRecognitionTask) and fold what it heard in
    /// here — callers see one continuous transcript across the seams.
    private var committedPrefix   = ""
    private var taskStartedAt     = Date()
    /// Roll the recognition request after this much continuous run time,
    /// at the next brief quiet moment.
    private let taskRefreshInterval: TimeInterval = 55
    private var lastTextChangeAt  = Date()
    private var lastCommitAt      = Date()

    /// The transcript as callers should see it: prior tasks' text plus the
    /// live task's text.
    private var fullText: String {
        if committedPrefix.isEmpty { return currentText }
        if currentText.isEmpty     { return committedPrefix }
        return committedPrefix + " " + currentText
    }
    /// Fires onSilence after this much quiet time post-speech. This is the
    /// dominant source of "delay before the AI replies" on the Apple
    /// backend. 0.9s balances mid-sentence pauses against responsiveness —
    /// closer to ElevenLabs' 0.6s server VAD so switching backends doesn't
    /// change how the app feels (the debounced grace window downstream is
    /// the second line of defence against half-questions).
    private let silenceThreshold: TimeInterval = 0.9
    private var silenceTimer:     DispatchSourceTimer?

    // MARK: - Lifecycle

    func start(source: AudioSource) async throws {
        guard !isRunning else { return }
        NSLog("[AppleTranscriber] start(source: %@)", String(describing: source))
        guard await requestPermission() else {
            NSLog("[AppleTranscriber] speech recognition permission denied")
            throw TranscriptionError.permissionDenied(
                "Speech recognition permission denied. Enable in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer else {
            NSLog("[AppleTranscriber] SFSpeechRecognizer is nil for locale %@",
                  Locale.current.identifier)
            throw TranscriptionError.unavailable
        }
        guard recognizer.isAvailable else {
            NSLog("[AppleTranscriber] recognizer not available (network down? language pack missing?)")
            throw TranscriptionError.unavailable
        }

        if source == .microphone || source == .both {
            guard await requestMicPermission() else {
                NSLog("[AppleTranscriber] microphone permission denied")
                throw TranscriptionError.permissionDenied(
                    "Microphone permission denied. Enable in System Settings → Privacy & Security.")
            }
        }

        if source == .microphone || source == .both {
            // Escalation state goes stale — see the matching note in
            // TranscriptionManager.setupMicCapture.
            if Date().timeIntervalSince(lastStallAt) > 60 {
                deadCaptureStreak     = 0
                preferVoiceProcessing = false
            }
            receivedAudio = false

            // `MicInput.startEngine` rebuilds the engine per attempt and
            // retries through the transient states the input device passes
            // through when another app (a WhatsApp/Zoom call) grabs or
            // releases it — where the old code read the format once and
            // gave up with "No audio input available".
            let watchdog = MicFlowWatchdog(label: "AppleTranscriber") { [weak self] reason in
                self?.handleMicStall(reason)
            }
            flowWatchdog = watchdog

            var bufferCount = 0
            let started = try await MicInput.startEngine(
                label: "AppleTranscriber",
                voiceProcessing: preferVoiceProcessing
            ) { [weak self] engine, format in
                engine.inputNode.removeTap(onBus: 0)
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                    watchdog.note(buf)
                    self?.request?.append(buf)
                    self?.noteVoiceActivity(buf)
                    bufferCount += 1
                    if bufferCount == 1 || bufferCount % 200 == 0 {
                        NSLog("[AppleTranscriber] mic buffer #%d frames=%u", bufferCount, buf.frameLength)
                    }
                    if bufferCount == 20 {
                        // ~1s of audio actually flowing clears the escalation.
                        DispatchQueue.main.async { [weak self] in
                            self?.deadCaptureStreak = 0
                            self?.receivedAudio     = true
                        }
                    }
                }
            }
            audioEngine = started.engine
            watchdog.noteStart()

            // Input device changes (AirPods battery dies, headset
            // unplugged) silently stop the engine — without this the UI
            // keeps saying "Listening" while no audio flows. Surface it
            // so the owner can restart capture on the new device.
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine, queue: .main
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                NSLog("[AppleTranscriber] engine configuration changed — capture interrupted")
                self.onCaptureInterrupted?()
            }

            // A Bluetooth headset entering call mode is a *device swap*,
            // which AVAudioEngine doesn't always report as a configuration
            // change.
            deviceMonitor.start { [weak self] in
                guard let self, self.isRunning else { return }
                NSLog("[AppleTranscriber] default input device changed — capture interrupted")
                self.onCaptureInterrupted?()
            }
        }

        if source == .systemAudio || source == .both {
            try await setupSystemAudioCapture()
        }

        isRunning = true
        currentText = ""
        committedPrefix = ""
        lastTextChangeAt = Date()
        lastVoiceAt        = .distantPast
        deadTaskRetried    = false
        deadEngineReported = false
        installRecognitionTask()
        NSLog("[AppleTranscriber] recognitionTask installed")
        startSilenceWatcher()
    }

    /// Create a fresh request + recognition task pair. Used at start and
    /// by the periodic long-run refresh. The handler checks a task token
    /// so callbacks from a superseded (cancelled) task — including its
    /// "canceled" error — are silently dropped.
    private var activeTaskID = UUID()
    /// Consecutive recognition tasks that died within seconds of starting.
    /// Routine task deaths (no-speech timeouts, server-side resets) are
    /// recovered by rolling a fresh task — but a task that fails INSTANTLY
    /// over and over signals something fatal (permission revoked, language
    /// pack gone), and rolling forever would spin a tight error loop.
    private var rapidTaskFailures = 0

    private func installRecognitionTask() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        // On-device when the installed language pack supports it: constant
        // low latency (no per-word server round-trip) and no server-side
        // duration kills. But macOS sometimes reports support while the
        // local model silently produces nothing — the dead-engine watchdog
        // in the silence watcher detects that within seconds and flips
        // `preferServerRecognition` so we never sit deaf trusting the flag.
        let onDevice = recognizer.supportsOnDeviceRecognition && !preferServerRecognition
        req.requiresOnDeviceRecognition = onDevice
        currentTaskOnDevice   = onDevice
        hasResultSinceInstall = false
        // Punctuated transcripts read better AND power the question-
        // completeness heuristic that keeps auto-mode from answering
        // mid-sentence (TranscriptFilter.seemsComplete).
        req.addsPunctuation             = true
        request = req
        taskStartedAt = Date()

        let taskID = UUID()
        activeTaskID = taskID
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.activeTaskID == taskID else { return }
                if let error {
                    NSLog("[AppleTranscriber] recognition error: %@", error.localizedDescription)
                    // SFSpeech tasks die routinely on long sessions
                    // ("no speech detected" after ~1min of quiet, server
                    // resets). Roll straight to a fresh task so the engine
                    // never sits deaf waiting for the periodic refresh —
                    // unless tasks are dying instantly back-to-back, which
                    // means something fatal that rolling can't fix.
                    let taskAge = Date().timeIntervalSince(self.taskStartedAt)
                    self.rapidTaskFailures = taskAge < 2 ? self.rapidTaskFailures + 1 : 0
                    if self.rapidTaskFailures < 3 {
                        self.refreshRecognitionTask()
                    } else {
                        (self.onError ?? self.onUpdate)?("Error: \(error.localizedDescription)")
                    }
                    return
                }
                guard let result else { return }
                self.rapidTaskFailures      = 0
                self.hasResultSinceInstall  = true
                self.deadTaskRetried        = false
                let text = result.bestTranscription.formattedString
                if text != self.currentText {
                    // Only RESTART the silence clock when the words actually
                    // changed. The recognizer keeps revising punctuation and
                    // casing after the speaker has stopped, and treating
                    // each revision as "new speech" pushed the commit out by
                    // an unpredictable amount — the same question sometimes
                    // answered fast, sometimes seconds late.
                    let substantive = TranscriptFilter.normalized(text)
                        != TranscriptFilter.normalized(self.currentText)
                    self.currentText = text
                    if substantive { self.lastTextChangeAt = Date() }
                    self.onUpdate?(self.fullText)
                    self.onPartial?(self.fullText)
                }
                if result.isFinal {
                    self.commitCurrent()
                }
            }
        }
    }

    /// Roll to a fresh recognition request. A single request degrades on
    /// long-running audio (and server-backed recognition enforces a hard
    /// duration cap), which used to kill transcription partway into long
    /// interviews. Current text folds into `committedPrefix` so the
    /// transcript reads continuous across the seam.
    private func refreshRecognitionTask() {
        guard isRunning else { return }
        NSLog("[AppleTranscriber] rolling recognition task after %.0fs",
              Date().timeIntervalSince(taskStartedAt))
        if !currentText.isEmpty {
            committedPrefix = fullText
            currentText = ""
        }
        let old = task
        old?.cancel()
        request?.endAudio()
        installRecognitionTask()
    }

    /// Drop everything heard so far and start a fresh recognition segment
    /// WITHOUT touching the audio engine or taps. Used right after a live
    /// send so the next utterance starts clean. The old path tore down the
    /// whole engine and restarted it (~0.8s deaf window) — and NOT
    /// resetting after a manual send made the already-sent text resurface
    /// on the next recognition update, double-sending the same question.
    func resetSegment() {
        guard isRunning else { return }
        committedPrefix  = ""
        currentText      = ""
        lastTextChangeAt = Date()
        task?.cancel()
        request?.endAudio()
        installRecognitionTask()
    }

    func stop() {
        isRunning = false
        silenceTimer?.cancel()
        silenceTimer = nil
        flowWatchdog?.stop()
        flowWatchdog = nil
        deviceMonitor.stop()

        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }

        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        Task { [scStream] in
            try? await scStream?.stopCapture()
        }
        scStream           = nil
        systemAudioHandler = nil

        currentText     = ""
        committedPrefix = ""
    }

    /// The tap is alive but no audio is coming through it. Escalate rather
    /// than sitting deaf behind a "Listening" label: restart on a fresh
    /// engine, then on the voice-processing input unit (which coexists with
    /// the VP clients call apps install), then tell the user what's holding
    /// the mic.
    private func handleMicStall(_ reason: String) {
        guard isRunning else { return }
        if Date().timeIntervalSince(lastStallAt) > 60 { deadCaptureStreak = 0 }
        lastStallAt        = Date()
        deadCaptureStreak += 1
        NSLog("[AppleTranscriber] mic stall #%d: %@", deadCaptureStreak, reason)
        if deadCaptureStreak >= 2 { preferVoiceProcessing = true }
        if deadCaptureStreak >= 3 {
            (onError ?? onUpdate)?("Error: \(reason). \(MicInput.troubleHint())")
        } else {
            onCaptureInterrupted?()
        }
    }

    /// Parity shim with `TranscriptionManager.stopAudioCapture()` — the
    /// Apple path has no separate capture/websocket layers so it's a no-op
    /// beyond stopping.
    func stopAudioCapture() { stop() }

    func sendCommit() { commitCurrent() }

    // MARK: - Silence detection (VAD-like)

    private func startSilenceWatcher() {
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 0.25s granularity keeps the worst-case commit latency near the
        // threshold instead of threshold + a coarse timer tick.
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }

            // Dead-engine watchdog: speech-level audio is flowing but the
            // task has produced NOTHING since install. On-device models
            // sometimes load slowly or silently fail even when the
            // recognizer claims support — without this, the user spoke
            // for ages with no transcript. Fall back to the server path,
            // retry once there, and only then tell the user.
            if !self.hasResultSinceInstall,
               Date().timeIntervalSince(self.taskStartedAt) > 3.5,
               self.lastVoiceAt > self.taskStartedAt.addingTimeInterval(0.3) {
                if self.currentTaskOnDevice {
                    NSLog("[AppleTranscriber] on-device task silent despite voice — falling back to server recognition")
                    self.preferServerRecognition = true
                    self.refreshRecognitionTask()
                } else if !self.deadTaskRetried {
                    self.deadTaskRetried = true
                    NSLog("[AppleTranscriber] recognition task silent despite voice — rolling a fresh task")
                    self.refreshRecognitionTask()
                } else if !self.deadEngineReported {
                    self.deadEngineReported = true
                    self.onError?("Error: speech recognition is not returning results. Check System Settings → Privacy & Security → Speech Recognition, or add an ElevenLabs key in Preferences for cloud transcription.")
                }
                return
            }

            let quietFor = Date().timeIntervalSince(self.lastTextChangeAt)
            // Long-run refresh: roll the recognition request at a quiet
            // moment once it's been alive past the interval — before the
            // recognizer degrades or kills it mid-interview.
            if Date().timeIntervalSince(self.taskStartedAt) > self.taskRefreshInterval,
               quietFor > 0.8 {
                self.refreshRecognitionTask()
            }
            guard !self.fullText.isEmpty else { return }
            let sinceCommit = Date().timeIntervalSince(self.lastCommitAt)
            // Only fire once per quiet period.
            if quietFor >= silenceThreshold && sinceCommit >= silenceThreshold {
                self.commitCurrent()
            }
        }
        timer.resume()
        silenceTimer = timer
    }

    private func commitCurrent() {
        guard !fullText.isEmpty else { return }
        lastCommitAt = Date()
        onCommit?(fullText)
        onSilence?()
    }

    /// Cheap voice-activity note from the capture threads. A coarse peak
    /// scan (every 64th sample) is enough to tell "someone is speaking"
    /// from silence/room noise — it powers the dead-engine watchdog, not
    /// transcription. Throttled so the main queue sees at most ~2
    /// notes/second.
    private func noteVoiceActivity(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var peak: Float = 0
        var i = 0
        while i < n {
            let v = abs(data[i])
            if v > peak { peak = v }
            i += 64
        }
        guard peak > 0.02 else { return }
        let now = Date()
        voiceNoteLock.lock()
        let shouldNote = now.timeIntervalSince(lastVoiceNoteAt) > 0.5
        if shouldNote { lastVoiceNoteAt = now }
        voiceNoteLock.unlock()
        guard shouldNote else { return }
        DispatchQueue.main.async { [weak self] in self?.lastVoiceAt = now }
    }

    // MARK: - Permissions

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - System audio capture (ScreenCaptureKit → SFSpeechRecognizer)

    private func setupSystemAudioCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw TranscriptionError.permissionDenied(
                "System audio error: \((error as NSError).localizedDescription). " +
                "Open System Settings → Privacy & Security → Screen Recording → enable thecloser," +
                "then QUIT and relaunch the app."
            )
        }
        guard let display = content.displays.first else { throw TranscriptionError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio        = true
        config.sampleRate           = 16000
        config.channelCount         = 1
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.width                = 2
        config.height               = 2

        let handler = AppleSystemAudioHandler { [weak self] buffer in
            self?.request?.append(buffer)
            self?.noteVoiceActivity(buffer)
        }
        handler.onStopped = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.onCaptureInterrupted?()
            }
        }
        systemAudioHandler = handler

        scStream = SCStream(filter: filter, configuration: config, delegate: handler)
        try scStream?.addStreamOutput(handler, type: .audio,
                                      sampleHandlerQueue: DispatchQueue(label: "com.macoverlay.apple.sysaudio"))
        try await scStream?.startCapture()
    }
}

// MARK: - System audio → AVAudioPCMBuffer adapter for SFSpeechRecognizer

final class AppleSystemAudioHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let format: AVAudioFormat?
    /// Stream died (display change, permission revoked, SCK hiccup) —
    /// owner should restart capture rather than sit deaf.
    var onStopped: (() -> Void)?

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        // ScreenCaptureKit delivers Float32 mono @ 16kHz when configured above.
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16000,
                                    channels: 1,
                                    interleaved: false)
        super.init()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              let format,
              let blockBuffer = sampleBuffer.dataBuffer else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        let frameCount = totalLength / MemoryLayout<Float32>.size
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let dst = pcm.floatChannelData?[0] else { return }

        ptr.withMemoryRebound(to: Float32.self, capacity: frameCount) { src in
            dst.update(from: src, count: frameCount)
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Apple system audio stream stopped: \(error.localizedDescription)")
        onStopped?()
    }
}
