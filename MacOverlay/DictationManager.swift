import AppKit

/// Hold ⌥ → streams mic through ElevenLabs scribe_v2_realtime WebSocket →
/// on release, pastes the committed transcript into the previously active app.
class DictationManager {

    private let tm               = TranscriptionManager()
    private var targetPID:         pid_t = 0
    private var accumulatedText  = ""   // committed segments while holding Option
    private var waitingForFinal  = false // true after Option released, waiting for last commit

    var onTranscript:    ((String) -> Void)?
    var onEngineStarted: (() -> Void)?
    var onStatus:        ((String) -> Void)?
    var onPasted:        (() -> Void)?

    // MARK: - Start

    func start(targetPID: pid_t, elevenLabsAPIKey: String) {
        self.targetPID = targetPID
        tm.elevenLabsAPIKey = elevenLabsAPIKey
        accumulatedText = ""
        waitingForFinal = false

        // Show live partials in the overlay (appended to accumulated committed text)
        tm.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let display = self.accumulatedText.isEmpty ? text : self.accumulatedText + " " + text
                self.onTranscript?(display)
            }
        }

        // ElevenLabs auto-commits on VAD silence gaps while Option is still held.
        // Accumulate those segments. Only paste when waitingForFinal is set (Option released).
        tm.onCommit = { [self] text in
            DispatchQueue.main.async {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                print("[Dictation] committed segment: \(trimmed) waitingForFinal=\(self.waitingForFinal)")

                // Append to accumulated text
                self.accumulatedText += (self.accumulatedText.isEmpty ? "" : " ") + trimmed
                self.onTranscript?(self.accumulatedText)

                if self.waitingForFinal {
                    // Option was already released — this is the last commit, paste now
                    self.tm.stop()
                    self.pasteIntoPreviousApp(self.accumulatedText)
                }
            }
        }

        Task {
            do {
                try await tm.start(source: .microphone)
                await MainActor.run { self.onEngineStarted?() }
                print("[Dictation] ElevenLabs started, pid=\(targetPID)")
            } catch {
                print("[Dictation] start error: \(error)")
                await MainActor.run { self.onStatus?("Error: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        waitingForFinal = true
        // Stop mic but keep WebSocket open for the final committed_transcript
        tm.stopAudioCapture()
        tm.sendCommit()

        // Fallback: if no committed_transcript arrives within 3s, paste what we have
        let snapshot = accumulatedText
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            guard self.tm.isRunning else { return }  // already handled by onCommit
            self.tm.stop()
            let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Dictation] fallback paste: \(trimmed)")
            guard !trimmed.isEmpty else {
                self.onStatus?("Nothing transcribed")
                return
            }
            self.pasteIntoPreviousApp(trimmed)
        }
    }

    // MARK: - Paste via clipboard + Cmd+V

    private func pasteIntoPreviousApp(_ text: String) {
        guard targetPID != 0 else {
            onStatus?("Click in a text field first, then hold Option")
            return
        }

        onStatus?("Pasting…")
        print("[Dictation] pasting \"\(text)\" to pid=\(targetPID)")

        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Bring the target app to front so its text field is focused
        if let app = NSWorkspace.shared.runningApplications
                        .first(where: { $0.processIdentifier == targetPID }) {
            app.activate(options: [.activateIgnoringOtherApps])
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
