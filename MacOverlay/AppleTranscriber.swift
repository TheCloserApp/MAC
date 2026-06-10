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
final class AppleTranscriber: NSObject {

    // MARK: - Public API (mirrors TranscriptionManager)

    var onUpdate:  ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onCommit:  ((String) -> Void)?
    var onSilence: (() -> Void)?
    /// Engine failures. When unset, errors fall back to `onUpdate`
    /// (legacy behaviour) — but consumers should set this so error
    /// strings never masquerade as transcript text.
    var onError:   ((String) -> Void)?

    private(set) var isRunning = false

    // MARK: - Private

    private var audioEngine  = AVAudioEngine()
    private var request:       SFSpeechAudioBufferRecognitionRequest?
    private var task:          SFSpeechRecognitionTask?
    private var recognizer:    SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)

    private var scStream:           SCStream?
    private var systemAudioHandler: AppleSystemAudioHandler?

    private var currentText       = ""
    private var lastTextChangeAt  = Date()
    private var lastCommitAt      = Date()
    /// Fires onSilence after this much quiet time post-speech. This is the
    /// dominant source of "delay before the AI replies" on the Apple
    /// backend — 1.2s keeps mid-sentence pauses from committing
    /// prematurely while staying responsive (ElevenLabs runs at 0.6s).
    private let silenceThreshold: TimeInterval = 1.2
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

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        req.requiresOnDeviceRecognition = false
        // Punctuated transcripts read better AND power the question-
        // completeness heuristic that keeps auto-mode from answering
        // mid-sentence (TranscriptFilter.seemsComplete).
        req.addsPunctuation             = true
        request = req

        if source == .microphone || source == .both {
            // Rebuild the engine on every start. The same `AVAudioEngine`
            // can refuse to re-tap after the default input device changes
            // (e.g. AirPods disconnect) — the node's reported format goes
            // stale and `installTap` silently produces no buffers. A fresh
            // engine forces CoreAudio to re-resolve the current input.
            audioEngine = AVAudioEngine()
            let node = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            NSLog("[AppleTranscriber] mic input format: %@ channels=%u sampleRate=%.0f",
                  format.description, format.channelCount, format.sampleRate)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw TranscriptionError.permissionDenied(
                    "No audio input available. Check that a microphone is selected as the default input in System Settings → Sound → Input, and that MacOverlay has Microphone permission.")
            }
            node.removeTap(onBus: 0)
            var bufferCount = 0
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.request?.append(buf)
                bufferCount += 1
                if bufferCount == 1 || bufferCount % 200 == 0 {
                    NSLog("[AppleTranscriber] mic buffer #%d frames=%u", bufferCount, buf.frameLength)
                }
            }
            audioEngine.prepare()
            do {
                try audioEngine.start()
                NSLog("[AppleTranscriber] AVAudioEngine started")
            } catch {
                NSLog("[AppleTranscriber] AVAudioEngine.start failed: %@", error.localizedDescription)
                throw error
            }
        }

        if source == .systemAudio || source == .both {
            try await setupSystemAudioCapture()
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let error {
                NSLog("[AppleTranscriber] recognition error: %@", error.localizedDescription)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    (self.onError ?? self.onUpdate)?("Error: \(error.localizedDescription)")
                }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                if text != self.currentText {
                    self.currentText = text
                    self.lastTextChangeAt = Date()
                    self.onUpdate?(text)
                    self.onPartial?(text)
                }
                if result.isFinal {
                    self.commitCurrent()
                }
            }
        }
        NSLog("[AppleTranscriber] recognitionTask installed")

        isRunning = true
        currentText = ""
        lastTextChangeAt = Date()
        startSilenceWatcher()
    }

    func stop() {
        isRunning = false
        silenceTimer?.cancel()
        silenceTimer = nil

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

        currentText = ""
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
            guard !self.currentText.isEmpty else { return }
            let quietFor = Date().timeIntervalSince(self.lastTextChangeAt)
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
        guard !currentText.isEmpty else { return }
        lastCommitAt = Date()
        onCommit?(currentText)
        onSilence?()
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
                "Open System Settings → Privacy & Security → Screen Recording → enable MacOverlay, " +
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
    }
}
