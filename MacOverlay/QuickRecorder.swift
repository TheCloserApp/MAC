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

    func start() throws {
        reset()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        req.requiresOnDeviceRecognition = false
        request = req

        let node = audioEngine.inputNode
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self.latestText = text
                self.onPartial?(text)
                if result.isFinal { self.deliver() }
            }
        }
    }

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
