import Speech
import AVFoundation
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

    private(set) var isRunning = false

    // MARK: - Private

    private var audioEngine  = AVAudioEngine()
    private var request:       SFSpeechAudioBufferRecognitionRequest?
    private var task:          SFSpeechRecognitionTask?
    private var recognizer:    SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)

    private var currentText       = ""
    private var lastTextChangeAt  = Date()
    private var lastCommitAt      = Date()
    /// Fires onSilence after this much quiet time post-speech.
    private let silenceThreshold: TimeInterval = 1.4
    private var silenceTimer:     DispatchSourceTimer?

    // MARK: - Lifecycle

    func start(source: AudioSource) async throws {
        // Only mic is supported (SFSpeechRecognizer cannot ingest system audio).
        // Caller should surface this limitation in the UI.
        _ = source

        guard !isRunning else { return }
        guard await requestPermission() else {
            throw TranscriptionError.permissionDenied(
                "Speech recognition permission denied. Enable in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }

        // Microphone permission (SFSpeechRecognizer needs both)
        guard await requestMicPermission() else {
            throw TranscriptionError.permissionDenied(
                "Microphone permission denied. Enable in System Settings → Privacy & Security.")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        req.requiresOnDeviceRecognition = false
        request = req

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.onUpdate?("Error: \(error.localizedDescription)")
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
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
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
}
