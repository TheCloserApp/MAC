import AVFoundation
import ScreenCaptureKit
import Foundation

class TranscriptionManager: NSObject {

    // MARK: - Public interface

    var onUpdate:  ((String) -> Void)?   // partial + committed (existing behaviour)
    var onPartial: ((String) -> Void)?   // partial only
    var onCommit:  ((String) -> Void)?   // committed only
    var onSilence: (() -> Void)?
    var elevenLabsAPIKey: String = ""

    private(set) var isRunning = false

    // MARK: - Private state

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession:    URLSession?

    private var audioEngine  = AVAudioEngine()
    private var converter:    AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private var scStream:           SCStream?
    private var systemAudioHandler: SystemAudioHandler?

    // MARK: - Public API

    func start(source: AudioSource) async throws {
        guard !isRunning else { return }

        if source == .microphone || source == .both {
            guard await requestMicPermission() else {
                throw TranscriptionError.permissionDenied(
                    "Microphone permission denied. Enable in System Settings → Privacy & Security.")
            }
        }

        try openWebSocket()
        isRunning = true   // set before audio callbacks fire

        if source == .microphone || source == .both {
            try setupMicCapture()
        }
        if source == .systemAudio || source == .both {
            try await setupSystemAudioCapture()
        }
    }

    func stop() {
        isRunning = false
        stopAudioCapture()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession    = nil
    }

    /// Stop mic/system audio but keep the WebSocket open so ElevenLabs
    /// can still deliver any in-flight committed_transcript.
    func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        converter    = nil
        targetFormat = nil
        Task {
            try? await scStream?.stopCapture()
            scStream           = nil
            systemAudioHandler = nil
        }
    }

    /// Ask ElevenLabs to immediately commit (finalize) whatever audio it has
    /// buffered. Call this right after stopping audio capture so the final
    /// committed_transcript arrives before we close the WebSocket.
    func sendCommit() {
        let msg = "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\",\"commit\":true,\"sample_rate\":16000}"
        webSocketTask?.send(.string(msg)) { _ in }
    }

    // MARK: - WebSocket

    private func openWebSocket() throws {
        guard !elevenLabsAPIKey.isEmpty else {
            throw TranscriptionError.permissionDenied("ElevenLabs API key not set. Add it in Settings (gear icon).")
        }

        // VAD commit strategy — server auto-commits utterances on silence
        let qs = "model_id=scribe_v2_realtime" +
                 "&audio_format=pcm_16000" +
                 "&commit_strategy=vad" +
                 "&language_code=en" +
                 "&vad_silence_threshold_secs=1.0"

        guard let url = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?\(qs)") else {
            throw TranscriptionError.unavailable
        }

        var request = URLRequest(url: url)
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        urlSession    = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveLoop()
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.webSocketTask != nil else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    print("[ElevenLabs] \(text.prefix(200))")
                    self.handleResponse(text)
                }
                self.receiveLoop()

            case .failure(let error):
                print("[ElevenLabs] WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.onUpdate?("Connection error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleResponse(_ json: String) {
        guard
            let data = json.data(using: .utf8),
            let msg  = try? JSONDecoder().decode(ElevenLabsMessage.self, from: data),
            let type = msg.message_type
        else { return }

        switch type {
        case "partial_transcript":
            let text = msg.text ?? ""
            if !text.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdate?(text)
                    self?.onPartial?(text)
                }
            }

        case "committed_transcript", "committed_transcript_with_timestamps":
            let text = msg.text ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !text.isEmpty {
                    self.onUpdate?(text)
                    self.onCommit?(text)
                }
                self.onSilence?()
            }

        case "session_started":
            print("[ElevenLabs] Session started")

        default:
            // Catch all error types from ElevenLabs
            if type.contains("error") || type.contains("Error") {
                let detail = msg.message ?? type
                print("[ElevenLabs] Error: \(detail)")
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdate?("ElevenLabs: \(detail)")
                }
            }
        }
    }

    // Audio → base64 JSON chunk (ElevenLabs format)
    private func sendAudio(_ pcm16: Data) {
        guard isRunning else { return }
        let payload = ElevenLabsAudioChunk(audio_base_64: pcm16.base64EncodedString())
        guard let json = try? JSONEncoder().encode(payload),
              let str  = String(data: json, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { _ in }
    }

    // MARK: - Mic capture

    private func setupMicCapture() throws {
        let inputNode   = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 16000,
                                      channels: 1,
                                      interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: fmt)
        else { throw TranscriptionError.unavailable }

        targetFormat = fmt
        converter    = conv

        // 800 frames = 50ms at 16kHz, matches ElevenLabs recommended chunk size
        inputNode.installTap(onBus: 0, bufferSize: 800, format: inputFormat) { [weak self] buf, _ in
            self?.convertAndSendMic(buf)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func convertAndSendMic(_ input: AVAudioPCMBuffer) {
        guard let conv = converter, let fmt = targetFormat else { return }

        let ratio    = 16000.0 / input.format.sampleRate
        let outCount = AVAudioFrameCount(max(1, Double(input.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCount) else { return }

        var consumed = false
        var convErr: NSError?
        conv.convert(to: output, error: &convErr) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return input
        }

        guard convErr == nil, output.frameLength > 0,
              let ch = output.int16ChannelData else { return }

        sendAudio(Data(bytes: ch[0], count: Int(output.frameLength) * 2))
    }

    // MARK: - System audio capture

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

        let handler = SystemAudioHandler { [weak self] data in self?.sendAudio(data) }
        systemAudioHandler = handler

        scStream = SCStream(filter: filter, configuration: config, delegate: handler)
        try scStream?.addStreamOutput(handler, type: .audio,
                                      sampleHandlerQueue: DispatchQueue(label: "com.macoverlay.sysaudio"))
        try await scStream?.startCapture()
    }

    // MARK: - Permissions

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }
}

// MARK: - System audio handler (Float32 → Int16)

class SystemAudioHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    private let onData: (Data) -> Void
    init(onData: @escaping (Data) -> Void) { self.onData = onData }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let blockBuffer = sampleBuffer.dataBuffer else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        let floatCount = totalLength / MemoryLayout<Float32>.size
        let floatPtr   = UnsafeRawPointer(ptr).bindMemory(to: Float32.self, capacity: floatCount)
        var int16Buf   = [Int16](repeating: 0, count: floatCount)
        for i in 0..<floatCount {
            int16Buf[i] = Int16(max(-1.0, min(1.0, floatPtr[i])) * 32767.0)
        }
        onData(int16Buf.withUnsafeBytes { Data($0) })
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("System audio stream stopped: \(error.localizedDescription)")
    }
}

// MARK: - ElevenLabs models

private struct ElevenLabsAudioChunk: Encodable {
    let message_type  = "input_audio_chunk"
    let audio_base_64: String
    let commit        = false
    let sample_rate   = 16000
}

private struct ElevenLabsMessage: Decodable {
    let message_type: String?
    let text:         String?
    let message:      String?  // error detail field
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case permissionDenied(String)
    case unavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return msg
        case .unavailable:               return "Transcription unavailable"
        case .noDisplay:                 return "No display found for system audio capture"
        }
    }
}
