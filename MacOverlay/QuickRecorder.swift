import Speech
import AVFoundation

/// Fast one-shot recorder using Apple SFSpeechRecognizer.
/// Returns a final transcript within ~200 ms of stopAndTranscribe() being called.
class QuickRecorder {

    static let shared = QuickRecorder()

    private var audioEngine  = AVAudioEngine()
    private var request:       SFSpeechAudioBufferRecognitionRequest?
    private var task:          SFSpeechRecognitionTask?
    private let recognizer   = SFSpeechRecognizer(locale: Locale.current)

    private var latestText   = ""
    private var delivered    = false
    private var completion:  ((String) -> Void)?

    var onPartial: ((String) -> Void)?

    // MARK: - Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Start

    func start() async throws {
        reset()
        NSLog("[QuickRecorder] start")

        guard let recognizer else {
            NSLog("[QuickRecorder] SFSpeechRecognizer is nil for locale %@",
                  Locale.current.identifier)
            throw QuickRecorderError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            NSLog("[QuickRecorder] recognizer not available (network down?)")
            throw QuickRecorderError.recognizerUnavailable
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        req.requiresOnDeviceRecognition = false
        request = req

        // `MicInput.startEngine` rebuilds the engine per attempt and retries
        // through the transient states the input device passes through when
        // another app grabs or releases it (a WhatsApp/Zoom call starting) —
        // re-tapping a stale engine silently produces no audio buffers.
        var bufferCount = 0
        let started = try await MicInput.startEngine(label: "QuickRecorder") { [weak self] engine, format in
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.request?.append(buf)
                bufferCount += 1
                if bufferCount == 1 || bufferCount % 200 == 0 {
                    NSLog("[QuickRecorder] mic buffer #%d frames=%u", bufferCount, buf.frameLength)
                }
            }
        }
        audioEngine = started.engine

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let error {
                NSLog("[QuickRecorder] recognition error: %@", error.localizedDescription)
            }
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self.latestText = text
                self.onPartial?(text)
                if result.isFinal { self.deliver() }
            }
        }
        NSLog("[QuickRecorder] recognitionTask installed")
    }

    enum QuickRecorderError: LocalizedError {
        case recognizerUnavailable
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognition is unavailable. Check your internet connection and that the system language is supported."
            }
        }
    }
    // Microphone-side failures come from `MicInput.Failure`, which names the
    // device and whatever is holding it.

    // MARK: - Stop

    /// Stop audio capture, signal end-of-audio to the recogniser, then call
    /// completion with the final transcript (or whatever partial was available).
    func stopAndTranscribe(completion: @escaping (String) -> Void) {
        self.completion = completion
        self.delivered  = false

        request?.endAudio()   // tell Apple STT "that's all the audio"
        stopAudio()

        // Fallback: if isFinal never arrives, deliver what we have after 1 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.deliver()
        }
    }

    // MARK: - Private

    private func deliver() {
        guard !delivered, let cb = completion else { return }
        delivered   = true
        completion  = nil
        task?.cancel()
        task        = nil
        request     = nil
        cb(latestText)
    }

    private func stopAudio() {
        guard audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func reset() {
        stopAudio()
        task?.cancel()
        task        = nil
        request     = nil
        latestText  = ""
        completion  = nil
        delivered   = false
    }
}
