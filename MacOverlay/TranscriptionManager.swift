import AVFoundation
import Speech
import ScreenCaptureKit

class TranscriptionManager: NSObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var scStream: SCStream?
    private var systemAudioHandler: SystemAudioHandler?

    var onUpdate: ((String) -> Void)?
    private(set) var isRunning = false

    // MARK: - Public API

    func start(source: AudioSource) async throws {
        guard !isRunning else { return }

        guard await requestSpeechPermission() else {
            throw TranscriptionError.permissionDenied("Speech recognition permission denied. Enable in System Settings → Privacy & Security.")
        }

        if source == .microphone || source == .both {
            guard await requestMicPermission() else {
                throw TranscriptionError.permissionDenied("Microphone permission denied. Enable in System Settings → Privacy & Security.")
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            if let result = result {
                self?.onUpdate?(result.bestTranscription.formattedString)
            }
        }

        if source == .microphone || source == .both {
            try setupMicCapture(request: request)
        }

        if source == .systemAudio || source == .both {
            try await setupSystemAudioCapture(request: request)
        }

        isRunning = true
    }

    func stop() {
        isRunning = false

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        Task {
            try? await scStream?.stopCapture()
            scStream = nil
            systemAudioHandler = nil
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    // MARK: - Private

    private func setupMicCapture(request: SFSpeechAudioBufferRecognitionRequest) throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func setupSystemAudioCapture(request: SFSpeechAudioBufferRecognitionRequest) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw TranscriptionError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimal video so stream is audio-only in practice
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.width = 2
        config.height = 2

        let handler = SystemAudioHandler(request: request)
        systemAudioHandler = handler

        scStream = SCStream(filter: filter, configuration: config, delegate: handler)
        try scStream?.addStreamOutput(handler, type: .audio,
                                      sampleHandlerQueue: DispatchQueue(label: "com.macoverlay.sysaudio"))
        try await scStream?.startCapture()
    }

    private func requestSpeechPermission() async -> Bool {
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

// MARK: - System Audio Handler

class SystemAudioHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    private weak var request: SFSpeechAudioBufferRecognitionRequest?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("System audio stream stopped: \(error.localizedDescription)")
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case permissionDenied(String)
    case unavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return msg
        case .unavailable:               return "Speech recognizer is not available"
        case .noDisplay:                 return "No display found for system audio capture"
        }
    }
}
