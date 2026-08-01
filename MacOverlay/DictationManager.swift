import AppKit

/// Common surface DictationManager drives, so it can run on either the
/// ElevenLabs Scribe socket OR Apple's on-device recognizer without caring
/// which. Both `TranscriptionManager` and `AppleTranscriber` already expose
/// these members; the empty conformances below just name that fact.
protocol DictationEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onCommit:  ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(source: AudioSource) async throws
    func stop()
    func stopAudioCapture()
    func sendCommit()
}

extension TranscriptionManager: DictationEngine {}
extension AppleTranscriber: DictationEngine {}

/// Hold ⌥ → streams the mic through a speech engine → on release, pastes the
/// committed transcript into the previously active app.
///
/// Engine selection: if an ElevenLabs key is set we use Scribe
/// (`scribe_v2_realtime`); otherwise we fall back to Apple's on-device
/// recognizer so dictation still works with no key / no network. The two
/// engines differ in how they report text — Scribe emits incremental
/// committed segments, Apple emits the cumulative transcript each update — so
/// the callbacks and the stop/commit flow branch on `usesApple`.
class DictationManager {

    private var tm: DictationEngine = TranscriptionManager()
    private var usesApple           = false
    private var targetPID:            pid_t = 0
    private var accumulatedText     = ""    // full transcript captured while holding Option
    private var waitingForFinal     = false // true after Option released, waiting for last commit
    private var hasPasted           = false // guard against a double paste from racing commits

    var onTranscript:    ((String) -> Void)?
    var onEngineStarted: (() -> Void)?
    var onStatus:        ((String) -> Void)?
    var onPasted:        (() -> Void)?

    // MARK: - Start

    func start(targetPID: pid_t, elevenLabsAPIKey: String) {
        self.targetPID = targetPID
        accumulatedText = ""
        waitingForFinal = false
        hasPasted       = false

        // Pick the engine. ElevenLabs Scribe when a key is present, else
        // Apple's on-device recognizer.
        if elevenLabsAPIKey.isEmpty {
            usesApple = true
            tm = AppleTranscriber()
        } else {
            usesApple = false
            let scribe = TranscriptionManager()
            scribe.elevenLabsAPIKey = elevenLabsAPIKey
            tm = scribe
        }

        if usesApple {
            // Apple reports the WHOLE transcript on every update, so we
            // REPLACE (never append) — appending would duplicate text.
            tm.onPartial = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.accumulatedText = text
                    self.onTranscript?(text)
                }
            }
            tm.onCommit = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    self.accumulatedText = trimmed
                    self.onTranscript?(trimmed)
                    if self.waitingForFinal {
                        self.tm.stop()
                        self.pasteIntoPreviousApp(trimmed)
                    }
                }
            }
        } else {
            // ElevenLabs partials describe only the CURRENT utterance, so the
            // display is accumulated committed text + the live partial, and
            // commits are APPENDED as discrete segments.
            tm.onPartial = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let display = self.accumulatedText.isEmpty
                        ? text : self.accumulatedText + " " + text
                    self.onTranscript?(display)
                }
            }
            tm.onCommit = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    print("[Dictation] committed segment (\(trimmed.count) chars) waitingForFinal=\(self.waitingForFinal)")
                    self.accumulatedText += (self.accumulatedText.isEmpty ? "" : " ") + trimmed
                    self.onTranscript?(self.accumulatedText)
                    if self.waitingForFinal {
                        self.tm.stop()
                        self.pasteIntoPreviousApp(self.accumulatedText)
                    }
                }
            }
        }

        Task {
            do {
                try await tm.start(source: .microphone)
                await MainActor.run { self.onEngineStarted?() }
                print("[Dictation] \(usesApple ? "Apple" : "ElevenLabs") started, pid=\(targetPID)")
            } catch {
                print("[Dictation] start error: \(error)")
                await MainActor.run { self.onStatus?("Error: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        waitingForFinal = true

        if usesApple {
            // Apple keeps recognizing until we stop it. Give it a beat to
            // flush the final partial, then commit — onCommit pastes. If the
            // commit is empty (nothing heard) no onCommit fires, so a backstop
            // stops the engine and reports.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                guard tm.isRunning else { return }
                tm.sendCommit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    guard tm.isRunning else { return }   // onCommit already pasted + stopped
                    tm.stop()
                    let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { onStatus?("Nothing transcribed") }
                    else               { pasteIntoPreviousApp(trimmed) }
                }
            }
            return
        }

        // ElevenLabs: stop the mic but keep the socket open for the final
        // committed_transcript; paste on that commit (above), or after a
        // timeout if it never arrives.
        tm.stopAudioCapture()
        tm.sendCommit()

        let snapshot = accumulatedText
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            guard self.tm.isRunning else { return }  // already handled by onCommit
            self.tm.stop()
            let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Dictation] fallback paste (\(trimmed.count) chars)")
            guard !trimmed.isEmpty else {
                self.onStatus?("Nothing transcribed")
                return
            }
            self.pasteIntoPreviousApp(trimmed)
        }
    }

    // MARK: - Paste via clipboard + Cmd+V

    private func pasteIntoPreviousApp(_ text: String) {
        guard !hasPasted else { return }   // racing commits must not double-paste
        hasPasted = true

        guard targetPID != 0 else {
            onStatus?("Click in a text field first, then hold Option")
            return
        }

        onStatus?("Pasting…")
        print("[Dictation] pasting \(text.count) chars to pid=\(targetPID)")

        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Bring the target app to front so its text field is focused
        if let app = NSWorkspace.shared.runningApplications
                        .first(where: { $0.processIdentifier == targetPID }) {
            app.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            let src   = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let vUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags   = .maskCommand
            vDown?.postToPid(self.targetPID)
            vUp?.postToPid(self.targetPID)
            print("[Dictation] Cmd+V sent to pid=\(self.targetPID)")
            self.onPasted?()

            if let saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(saved, forType: .string)
                }
            }
        }
    }
}
