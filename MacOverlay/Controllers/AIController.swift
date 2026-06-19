import AppKit
import Foundation
import Observation

/// Owns everything related to AI requests: system prompt resolution, streaming
/// lifecycle, retry-on-failure state, and background title regeneration.
/// The VM remains the single source of truth for persisted state (API keys,
/// session store, prompt store, etc.) — this class orchestrates flows on top.
@Observable
@MainActor
final class AIController {
    /// Captured on every send so the UI can offer a Retry button if the
    /// stream fails. Nil when there's no failed request to retry.
    struct PendingRetry {
        let userText: String
        let screenshot: NSImage?
        let systemPrompt: String
        let history: [(user: String, assistant: String)]
        let assistantTurnID: UUID
    }

    @ObservationIgnored private weak var vm: OverlayViewModel?
    /// In-flight streams keyed by their assistant turn id. A new question no
    /// longer cancels the previous answer — both generate at once — so we
    /// track every running stream instead of a single task handle.
    @ObservationIgnored private var activeStreams: [UUID: Task<Void, Never>] = [:]
    /// Turn ids oldest→newest, so the cap can evict the OLDEST running answer.
    @ObservationIgnored private var streamOrder: [UUID] = []
    /// Most-recently-started stream — it owns the `vm.aiResponse` mirror that
    /// the secondary status views (top strip, response panel) read.
    @ObservationIgnored private var currentStreamID: UUID?
    /// How many answers may generate concurrently. A new question past the
    /// cap evicts the oldest still-running answer (latest wins on overflow).
    static let maxConcurrentStreams = 2

    @ObservationIgnored private(set) var lastRetry: PendingRetry?
    /// The most recent request regardless of outcome. `lastRetry` clears
    /// on success (it gates the error-Retry UI), but Regenerate must keep
    /// working after a good answer — without this it silently no-opped.
    @ObservationIgnored private(set) var lastRequest: PendingRetry?

    var canRetry: Bool { lastRetry != nil }

    /// True while the given assistant turn is still streaming. Lets the UI
    /// show a per-answer typing indicator / Stop even when a different pair
    /// is in focus.
    func isStreaming(turnID: UUID) -> Bool { activeStreams[turnID] != nil }

    /// Keep `vm.isSendingToAI` in lockstep with "any stream running".
    private func syncSendingFlag() { vm?.isSendingToAI = !activeStreams.isEmpty }

    init(vm: OverlayViewModel) {
        self.vm = vm
    }

    // MARK: - Prompt resolution

    /// Active-prompt preset > mode default. Substitutes {NAME}/{ROLE}/{COMPANY}.
    func resolveActivePrompt() -> String {
        guard let vm else { return "" }
        let raw = vm.promptStore.activePreset?.content ?? vm.sessionMode.systemPrompt
        return raw
            .replacingOccurrences(of: "{NAME}",    with: vm.userProfile.name.isEmpty        ? "the user"       : vm.userProfile.name)
            .replacingOccurrences(of: "{ROLE}",    with: vm.userProfile.currentRole.isEmpty ? "a professional" : vm.userProfile.currentRole)
            .replacingOccurrences(of: "{COMPANY}", with: vm.userProfile.company.isEmpty     ? "their company"  : vm.userProfile.company)
    }

    // MARK: - Streaming

    /// Run a streaming request, mutating the given assistant turn as chunks
    /// arrive. Captures retry state so `retry()` can replay it on failure.
    func runStream(userText: String,
                   screenshot: NSImage?,
                   systemPrompt: String,
                   history: [(user: String, assistant: String)],
                   assistantTurnID: UUID,
                   wasFirstExchange: Bool) {
        guard let vm else { return }

        // Concurrent answers: a new question does NOT cancel the previous one
        // — both finish. If this exact turn is already running (Retry /
        // Regenerate), drop it first so it doesn't double-run. Then enforce
        // the cap by evicting the OLDEST still-running answer (latest wins on
        // overflow).
        cancelStream(turnID: assistantTurnID)
        while activeStreams.count >= AIController.maxConcurrentStreams,
              let oldest = streamOrder.first {
            cancelStream(turnID: oldest)
        }

        lastRetry = PendingRetry(
            userText: userText,
            screenshot: screenshot,
            systemPrompt: systemPrompt,
            history: history,
            assistantTurnID: assistantTurnID
        )
        lastRequest = lastRetry
        currentStreamID = assistantTurnID
        vm.aiResponse   = ""

        let task = Task { @MainActor [weak self, weak vm] in
            guard let self, let vm else { return }
            var accumulated = ""
            // Per-stream throttle: each concurrent answer paces its own store
            // writes so two streams don't starve each other's updates.
            var lastFlush = ContinuousClock.now
            var streamFailed = false
            // Only the newest stream mirrors onto the shared `aiResponse`
            // (secondary status views show the latest answer). Background
            // answers still update their own turn via the session store.
            // A @MainActor closure (not a nested func) so it keeps the task's
            // actor isolation when touching `currentStreamID` / `aiResponse`.
            let mirrorIfCurrent: @MainActor (String) -> Void = { text in
                if self.currentStreamID == assistantTurnID { vm.aiResponse = text }
            }
            do {
                let stream = AIManager.shared.streamMessage(
                    userText,
                    apiKey:         vm.apiKey,
                    openAIApiKey:   vm.openAIApiKey,
                    moonshotAPIKey: vm.moonshotAPIKey,
                    grokAPIKey:     vm.grokAPIKey,
                    deepSeekAPIKey: vm.deepSeekAPIKey,
                    model:          vm.selectedModel,
                    screenshot:     screenshot,
                    systemPrompt:   systemPrompt,
                    history:        history
                )
                for try await event in stream {
                    switch event {
                    case .chunk(let text):
                        accumulated += text
                        // Batched at ~30Hz: each store write copies the
                        // session value, invalidates every observer, and
                        // re-parses the turn's markdown. Per-token writes
                        // made long answers feel slower the longer they
                        // got (O(n²) total parse work).
                        let now = ContinuousClock.now
                        if now - lastFlush >= .milliseconds(33) {
                            vm.sessionStore.setStreamingContent(accumulated,
                                                                turnID: assistantTurnID)
                            mirrorIfCurrent(accumulated)
                            lastFlush = now
                        }
                    case .usage(let inTok, let outTok):
                        vm.sessionStore.finalizeAssistant(turnID: assistantTurnID,
                                                          inputTokens: inTok,
                                                          outputTokens: outTok)
                    }
                }
                // Final flush so the trailing tokens land even if they
                // arrived inside the last 33ms window.
                vm.sessionStore.setStreamingContent(accumulated, turnID: assistantTurnID)
                mirrorIfCurrent(accumulated)

                if wasFirstExchange {
                    let s = vm.sessionStore.activeSession
                    self.regenerateTitle(for: s, sessionID: s.id)
                }

                if !accumulated.isEmpty {
                    vm.notesManager.add(content: accumulated, source: .ai, mode: vm.sessionMode)
                    vm.sessionNotes = vm.notesManager.entries
                }
            } catch is CancellationError {
                // User hit Stop, or the cap evicted this answer. Keep whatever
                // streamed — no error decoration, no retry-state churn.
                streamFailed = true
                vm.sessionStore.setStreamingContent(accumulated, turnID: assistantTurnID)
                mirrorIfCurrent(accumulated)
            } catch {
                streamFailed = true
                let errMsg = "Error: \(error.localizedDescription)"
                let display = accumulated.isEmpty ? errMsg : accumulated + "\n\n" + errMsg
                // Replace (not append): the throttled store may not have
                // the full accumulated text yet.
                vm.sessionStore.setStreamingContent(display, turnID: assistantTurnID)
                mirrorIfCurrent(display)
            }
            // Retire this stream. Guard against a straggler completion for a
            // turn that was already cancelled + replaced (removeAll/nil are
            // both no-ops in that case).
            self.activeStreams[assistantTurnID] = nil
            self.streamOrder.removeAll { $0 == assistantTurnID }
            self.syncSendingFlag()
            if !streamFailed {
                self.lastRetry = nil
                // Anything the interviewer said while we were streaming is
                // queued in the live transcript — send it now instead of
                // waiting for a silence boundary that may never come.
                vm.flushPendingLiveTranscript()
            }
        }
        // Register before the task suspends (we're on @MainActor, so the body
        // can't run until this synchronous code yields).
        activeStreams[assistantTurnID] = task
        streamOrder.append(assistantTurnID)
        syncSendingFlag()
    }

    /// Reset the assistant turn and replay the last request — the failed
    /// one when there is one, otherwise the last successful one
    /// (Regenerate).
    func retry() {
        guard let r = lastRetry ?? lastRequest, let vm else { return }
        // Don't double-run a turn that's already streaming.
        guard activeStreams[r.assistantTurnID] == nil else { return }
        vm.resetAssistantTurn(id: r.assistantTurnID)
        runStream(userText: r.userText,
                  screenshot: r.screenshot,
                  systemPrompt: r.systemPrompt,
                  history: r.history,
                  assistantTurnID: r.assistantTurnID,
                  wasFirstExchange: false)
    }

    /// Cancel one specific answer (per-pair Stop, or cap eviction).
    func cancelStream(turnID: UUID) {
        guard let task = activeStreams[turnID] else { return }
        task.cancel()
        activeStreams[turnID] = nil
        streamOrder.removeAll { $0 == turnID }
        syncSendingFlag()
    }

    /// Cancel every in-flight answer (global Stop, session end / switch).
    func cancel() {
        for task in activeStreams.values { task.cancel() }
        activeStreams.removeAll()
        streamOrder.removeAll()
        currentStreamID = nil
        vm?.isSendingToAI = false
    }

    // MARK: - Title regeneration

    /// Background AI call that replaces an auto-generated title with a short,
    /// specific one once the session has a few turns. No-op if the user has
    /// renamed the session manually.
    func regenerateTitle(for session: ChatSession, sessionID: UUID) {
        guard let vm else { return }
        guard !session.titleManuallySet else { return }
        guard !session.turns.isEmpty else { return }
        let hasKey = AIManager.shared.isOpenAIModel(vm.selectedModel)
            ? !vm.openAIApiKey.isEmpty : !vm.apiKey.isEmpty
        guard hasKey else { return }

        let transcript = session.turns.prefix(8).map {
            "\($0.role.rawValue.capitalized): \($0.content)"
        }.joined(separator: "\n\n")

        let prompt = """
        Write a short 3-to-5 word title for this conversation. Return ONLY the title as plain text — no quotes, no punctuation, no explanation.

        Conversation:
        \(transcript)
        """

        let apiKeyCopy = vm.apiKey
        let openAIKeyCopy = vm.openAIApiKey

        Task { [weak vm] in
            do {
                let raw = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey: apiKeyCopy,
                    openAIApiKey: openAIKeyCopy,
                    model: "claude-haiku-4-5-20251001",
                    screenshot: nil,
                    systemPrompt: "You write concise, specific conversation titles."
                )
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: ".", with: "")
                guard !cleaned.isEmpty, cleaned.count < 80 else { return }
                vm?.sessionStore.setAutoTitle(id: sessionID, to: cleaned)
            } catch {
                // Silent: keep the first-message preview title.
            }
        }
    }
}
