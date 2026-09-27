import AVFoundation
import ScreenCaptureKit
import Foundation

/// `@unchecked Sendable`: callbacks hop between the audio render thread,
/// URLSession's queue, and main — but every mutation of shared state is
/// funnelled through the main queue, which is the invariant the compiler
/// can't see (hence "unchecked").
class TranscriptionManager: NSObject, @unchecked Sendable {

    // MARK: - Public interface

    var onUpdate:  ((String) -> Void)?   // partial + committed (existing behaviour)
    var onPartial: ((String) -> Void)?   // partial only
    var onCommit:  ((String) -> Void)?   // committed only
    var onSilence: (() -> Void)?
    /// Engine/connection failures. When unset, errors fall back to
    /// `onUpdate` (legacy behaviour) — but consumers should set this so
    /// error strings never masquerade as transcript text.
    var onError:   ((String) -> Void)?
    /// Connection lifecycle for the UI. WebSockets drop routinely (network
    /// blips, server-side idle timeouts, laptop sleep) — the manager
    /// reconnects automatically and only reports `.failed` after several
    /// straight failures.
    enum ConnectionEvent {
        case reconnecting(attempt: Int)
        case reconnected
        case failed(String)
    }
    var onConnectionEvent: ((ConnectionEvent) -> Void)?
    /// Audio capture died underneath us (input device disconnected,
    /// system-audio stream stopped). The owner should restart capture.
    var onCaptureInterrupted: (() -> Void)?

    /// The cloud engine audio is streamed to. Both take the same 16 kHz
    /// PCM; they differ only in the WebSocket protocol.
    enum Provider {
        case elevenLabs
        /// xAI's Grok Voice Transcribe 2.0. See GrokTranscription.swift.
        case grok

        var name: String { self == .elevenLabs ? "ElevenLabs" : "Grok" }
    }
    /// Set before `start`; takes effect from the next connection.
    var provider: Provider = .elevenLabs
    var elevenLabsAPIKey: String = ""
    var grokAPIKey: String = ""

    private(set) var isRunning = false

    // MARK: - Private state

    /// Consecutive failed connection attempts since the last healthy
    /// `session_started`. Only touched on the main queue.
    private var reconnectAttempts = 0
    /// After this many straight failures the UI is told the connection is
    /// down (`.failed`) — but reconnection KEEPS RUNNING in the background
    /// for as long as the session is live. Hours-long interviews ride out
    /// wifi blips, sleep/wake, and VPN flaps far longer than any fixed
    /// attempt budget; audio capture never stops, so the moment the
    /// network returns the transcript picks back up.
    private let reconnectAttemptsBeforeWarning = 5

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession:    URLSession?

    /// Grok takes no audio until it says `transcript.created`. Until then
    /// audio waits here (up to 3 s), so the first words aren't lost.
    /// Guarded by `grokLock`: audio arrives on the capture threads.
    private var grokReady = false
    private var grokPending = Data()
    private let grokLock = NSLock()
    private static let grokPendingLimit = 96_000   // 3 s of 16 kHz PCM16
    /// The utterance being stitched from Grok's chunks. Main queue only.
    private var grokUtterance = GrokTranscription.Utterance()

    private var audioEngine  = AVAudioEngine()
    private var converter:    AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var engineObserver: NSObjectProtocol?
    private let deviceMonitor = MicInput.DeviceMonitor()

    /// Detects a tap that installed but never delivered — see MicInput.swift.
    private var flowWatchdog: MicFlowWatchdog?
    /// Consecutive capture starts that produced no audio. Escalates:
    /// 1st → restart on a fresh engine, 2nd → restart with the
    /// voice-processing input unit (coexists with call apps' VP clients),
    /// 3rd → tell the user what's holding the mic.
    private var deadCaptureStreak  = 0
    private var preferVoiceProcessing = false
    private var lastStallAt = Date.distantPast
    /// Set once any mic audio has been captured this run — lets callers
    /// tell "you said nothing" apart from "the mic never opened".
    private(set) var receivedAudio = false

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

        reconnectAttempts = 0
        receivedAudio     = false
        try openWebSocket()
        isRunning = true   // set before audio callbacks fire

        if source == .microphone || source == .both {
            try await setupMicCapture()
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
        // Invalidate, don't just drop: URLSession instances are retained
        // by the system until invalidated, so a session that reconnected
        // many times over hours would otherwise accumulate dead sessions.
        urlSession?.finishTasksAndInvalidate()
        urlSession    = nil
    }

    /// Stop mic/system audio but keep the WebSocket open so ElevenLabs
    /// can still deliver any in-flight committed_transcript.
    func stopAudioCapture() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        deviceMonitor.stop()
        flowWatchdog?.stop()
        flowWatchdog = nil
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
        let msg: String
        switch provider {
        case .elevenLabs:
            msg = "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\",\"commit\":true,\"sample_rate\":16000}"
        case .grok:
            msg = "{\"type\":\"finalize\"}"
        }
        webSocketTask?.send(.string(msg)) { _ in }
    }

    // MARK: - WebSocket

    private func openWebSocket() throws {
        let request: URLRequest
        switch provider {
        case .elevenLabs: request = try elevenLabsRequest()
        case .grok:       request = try grokRequest()
        }

        // Tear down the previous session before replacing it (see stop()).
        urlSession?.finishTasksAndInvalidate()
        let session = URLSession(configuration: .default)
        urlSession    = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveLoop()
    }

    private func grokRequest() throws -> URLRequest {
        guard !grokAPIKey.isEmpty else {
            throw TranscriptionError.permissionDenied("xAI API key not set. Add it in Settings → AI.")
        }
        guard let url = GrokTranscription.streamURL(language: TranscriptionLanguage.current.elevenLabsCode) else {
            throw TranscriptionError.unavailable
        }
        grokLock.lock()
        grokReady = false
        grokPending.removeAll()
        grokLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.grokUtterance = GrokTranscription.Utterance() }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(grokAPIKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func elevenLabsRequest() throws -> URLRequest {
        guard !elevenLabsAPIKey.isEmpty else {
            throw TranscriptionError.permissionDenied("ElevenLabs API key not set. Add it in Settings (gear icon).")
        }

        // VAD commit strategy — server auto-commits utterances on silence.
        // The silence threshold is the dominant source of "delay before the
        // AI replies": the server waits this long after the speaker stops
        // before committing the segment that triggers `sendToAI`. 0.6s keeps
        // mid-sentence pauses from committing prematurely while shaving ~400ms
        // off every turn vs. the old 1.0s.
        let qs = "model_id=scribe_v2_realtime" +
                 "&audio_format=pcm_16000" +
                 "&commit_strategy=vad" +
                 "&language_code=\(TranscriptionLanguage.current.elevenLabsCode)" +
                 "&vad_silence_threshold_secs=0.6"

        guard let url = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?\(qs)") else {
            throw TranscriptionError.unavailable
        }

        var request = URLRequest(url: url)
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self, weak task] result in
            // Identity check: a straggler callback from a torn-down socket
            // must not process messages for — or tear down — the socket
            // that replaced it after a reconnect.
            guard let self, let task, self.webSocketTask === task else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    // Don't log message bodies — they carry the user's
                    // (and interviewer's) spoken words.
                    switch self.provider {
                    case .elevenLabs: self.handleResponse(text)
                    case .grok:       self.handleGrokEvent(text)
                    }
                }
                self.receiveLoop()

            case .failure(let error):
                print("[\(self.provider.name)] WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.handleSocketFailure(error)
                }
            }
        }
    }

    /// Reconnect with capped exponential backoff (0.5 → 1 → 2 → 4 → 5s,
    /// then every 5s indefinitely). Audio capture keeps running the whole
    /// time — only the WebSocket is rebuilt — so at most the in-flight
    /// utterance is lost. The user sees "Reconnecting…" via
    /// `onConnectionEvent`; after several straight failures they get the
    /// louder `.failed` message, but retries continue for as long as the
    /// session is running — a long outage must never permanently kill
    /// transcription mid-interview. Main queue only.
    private func handleSocketFailure(_ error: Error) {
        guard isRunning else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let delay = min(0.5 * pow(2.0, Double(attempt - 1)), 5.0)
        NSLog("[TranscriptionManager] socket failed (%@); reconnect attempt %d in %.1fs",
              error.localizedDescription, attempt, delay)
        if attempt == reconnectAttemptsBeforeWarning {
            let msg = "Transcription connection lost: \(error.localizedDescription). Still retrying — check your network and \(provider == .grok ? "xAI" : "ElevenLabs") key."
            if let onConnectionEvent {
                onConnectionEvent(.failed(msg))
            } else {
                (onError ?? onUpdate)?(msg)
            }
        } else {
            onConnectionEvent?(.reconnecting(attempt: attempt))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.webSocketTask == nil else { return }
            do {
                try self.openWebSocket()
            } catch {
                self.handleSocketFailure(error)
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.reconnectAttempts > 0 {
                    self.onConnectionEvent?(.reconnected)
                }
                self.reconnectAttempts = 0
            }

        default:
            // Catch all error types from ElevenLabs
            if type.contains("error") || type.contains("Error") {
                let detail = msg.message ?? type
                print("[ElevenLabs] Error: \(detail)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    (self.onError ?? self.onUpdate)?("ElevenLabs: \(detail)")
                }
            }
        }
    }

    /// Grok's events. Stitching happens on the main queue, where the
    /// callbacks run.
    private func handleGrokEvent(_ json: String) {
        guard let event = GrokTranscription.Event.parse(json) else { return }
        switch event.type {
        case "transcript.created":
            grokLock.lock()
            grokReady = true
            let pending = grokPending
            grokPending.removeAll()
            grokLock.unlock()
            if !pending.isEmpty { webSocketTask?.send(.data(pending)) { _ in } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.reconnectAttempts > 0 { self.onConnectionEvent?(.reconnected) }
                self.reconnectAttempts = 0
            }

        case "transcript.partial":
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch self.grokUtterance.handle(event) {
                case .partial(let text)?:
                    self.onUpdate?(text)
                    self.onPartial?(text)
                case .commit(let text)?:
                    if !text.isEmpty {
                        self.onUpdate?(text)
                        self.onCommit?(text)
                    }
                    self.onSilence?()
                case nil:
                    break
                }
            }

        case "error":
            let detail = event.message ?? "unknown error"
            print("[Grok] Error: \(detail)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                (self.onError ?? self.onUpdate)?("Grok: \(detail)")
            }

        default:
            break
        }
    }

    // Audio → the provider's format: base64 JSON chunks for ElevenLabs,
    // raw binary frames for Grok (held back until it's ready).
    private func sendAudio(_ pcm16: Data) {
        guard isRunning else { return }
        if provider == .grok {
            grokLock.lock()
            guard grokReady else {
                grokPending.append(pcm16)
                if grokPending.count > Self.grokPendingLimit {
                    grokPending.removeFirst(grokPending.count - Self.grokPendingLimit)
                }
                grokLock.unlock()
                return
            }
            grokLock.unlock()
            webSocketTask?.send(.data(pcm16)) { _ in }
            return
        }
        let payload = ElevenLabsAudioChunk(audio_base_64: pcm16.base64EncodedString())
        guard let json = try? JSONEncoder().encode(payload),
              let str  = String(data: json, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { _ in }
    }

    // MARK: - Mic capture

    private func setupMicCapture() async throws {
        // Escalation state goes stale. The VM's self-healing restart calls
        // stop() → start() again, so the streak has to survive a restart —
        // but a session started long after the last stall must go back to
        // the plain input path: voice processing brings echo cancellation
        // with it, which we don't want unless something needs it.
        if Date().timeIntervalSince(lastStallAt) > 60 {
            deadCaptureStreak     = 0
            preferVoiceProcessing = false
        }

        // `MicInput.startEngine` builds a FRESH engine per attempt and
        // retries through transient device reconfiguration — the state the
        // input device sits in for a moment whenever another app (a
        // WhatsApp/Zoom call) grabs or releases it. The old code read the
        // format once and gave up with "No audio input available" if it
        // came back 0 Hz.
        let watchdog = MicFlowWatchdog(label: "TranscriptionManager") { [weak self] reason in
            self?.handleMicStall(reason)
        }
        flowWatchdog = watchdog

        var bufferCount = 0
        let started = try await MicInput.startEngine(
            label: "TranscriptionManager",
            voiceProcessing: preferVoiceProcessing
        ) { [weak self] engine, inputFormat in
            guard let self else { return }
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true),
                  let conv = AVAudioConverter(from: inputFormat, to: fmt)
            else { throw TranscriptionError.unavailable }

            self.targetFormat = fmt
            self.converter    = conv

            engine.inputNode.removeTap(onBus: 0)
            // 800 frames = 50ms at 16kHz, matches ElevenLabs recommended chunk size
            engine.inputNode.installTap(onBus: 0, bufferSize: 800, format: inputFormat) { [weak self] buf, _ in
                watchdog.note(buf)
                self?.convertAndSendMic(buf)
                bufferCount += 1
                if bufferCount == 1 || bufferCount % 200 == 0 {
                    NSLog("[TranscriptionManager] mic buffer #%d frames=%u", bufferCount, buf.frameLength)
                }
                // ~1s of audio actually flowing clears the escalation.
                if bufferCount == 20 {
                    DispatchQueue.main.async { [weak self] in
                        self?.deadCaptureStreak = 0
                        self?.receivedAudio     = true
                    }
                }
            }
        }
        audioEngine = started.engine
        watchdog.noteStart()

        // Input device changes (AirPods battery dies, headset unplugged)
        // silently stop the engine — without this the UI keeps saying
        // "Listening" while no audio flows. Surface it so the owner can
        // restart capture on the new device.
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            NSLog("[TranscriptionManager] engine configuration changed — capture interrupted")
            self.onCaptureInterrupted?()
        }

        // A Bluetooth headset entering call mode is a *device swap*, which
        // AVAudioEngine doesn't always report as a configuration change.
        deviceMonitor.start { [weak self] in
            guard let self, self.isRunning else { return }
            NSLog("[TranscriptionManager] default input device changed — capture interrupted")
            self.onCaptureInterrupted?()
        }
    }

    /// The tap is alive but no audio is coming through it. Escalate rather
    /// than sitting deaf behind a "Listening" label.
    private func handleMicStall(_ reason: String) {
        guard isRunning else { return }
        if Date().timeIntervalSince(lastStallAt) > 60 { deadCaptureStreak = 0 }
        lastStallAt        = Date()
        deadCaptureStreak += 1
        NSLog("[TranscriptionManager] mic stall #%d: %@", deadCaptureStreak, reason)
        if deadCaptureStreak >= 2 { preferVoiceProcessing = true }
        if deadCaptureStreak >= 3 {
            (onError ?? onUpdate)?("Error: \(reason). \(MicInput.troubleHint())")
        } else {
            onCaptureInterrupted?()
        }
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
                "Open System Settings → Privacy & Security → Screen Recording → enable TheCloser," +
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
        handler.onStopped = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.onCaptureInterrupted?()
            }
        }
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
    /// Stream died (display change, permission revoked, SCK hiccup) —
    /// owner should restart capture rather than sit deaf.
    var onStopped: (() -> Void)?
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
        onStopped?()
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
