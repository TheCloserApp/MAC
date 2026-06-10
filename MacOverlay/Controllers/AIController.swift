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
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var lastRetry: PendingRetry?
    /// Last time we mirrored the streaming buffer onto `vm.aiResponse`.
    /// Used to throttle the assignment so SwiftUI doesn't invalidate every
    /// observer of `vm` on every token (~30+/sec). The chat surface itself
    /// reads from `session.turns` and still updates per-chunk — this only
    /// rate-limits the secondary status views (top strip, response panel).
    @ObservationIgnored private var lastResponseFlushAt: ContinuousClock.Instant = .now

    var canRetry: Bool { lastRetry != nil }

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
        lastRetry = PendingRetry(
            userText: userText,
            screenshot: screenshot,
            systemPrompt: systemPrompt,
            history: history,
            assistantTurnID: assistantTurnID
        )
        vm.isSendingToAI = true
        vm.aiResponse    = ""
        lastResponseFlushAt = .now

        streamingTask = Task { @MainActor [weak self, weak vm] in
            guard let self, let vm else { return }
            var accumulated = ""
            var streamFailed = false
            do {
                let stream = AIManager.shared.streamMessage(
                    userText,
                    apiKey:       vm.apiKey,
                    openAIApiKey: vm.openAIApiKey,
                    model:        vm.selectedModel,
                    screenshot:   screenshot,
                    systemPrompt: systemPrompt,
                    history:      history
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
                        if now - self.lastResponseFlushAt >= .milliseconds(33) {
                            vm.sessionStore.setStreamingContent(accumulated,
                                                                turnID: assistantTurnID)
                            vm.aiResponse = accumulated
                            self.lastResponseFlushAt = now
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
                if vm.aiResponse != accumulated {
                    vm.aiResponse = accumulated
                }

                if wasFirstExchange {
                    let s = vm.sessionStore.activeSession
                    self.regenerateTitle(for: s, sessionID: s.id)
                }

                if !accumulated.isEmpty {
                    vm.notesManager.add(content: accumulated, source: .ai, mode: vm.sessionMode)
                    vm.sessionNotes = vm.notesManager.entries
                }
                self.lastRetry = nil
            } catch {
                streamFailed = true
                let errMsg = "Error: \(error.localizedDescription)"
                let display = accumulated.isEmpty ? errMsg : accumulated + "\n\n" + errMsg
                vm.aiResponse = display
                // Replace (not append): the throttled store may not have
                // the full accumulated text yet.
                vm.sessionStore.setStreamingContent(display, turnID: assistantTurnID)
            }
            vm.isSendingToAI = false
            self.streamingTask = nil
            if !streamFailed {
                self.lastRetry = nil
                // Anything the interviewer said while we were streaming is
                // queued in the live transcript — send it now instead of
                // waiting for a silence boundary that may never come.
                vm.flushPendingLiveTranscript()
            }
        }
    }

    /// Reset the assistant turn and replay the last failed request.
    func retry() {
        guard let r = lastRetry, let vm else { return }
        vm.resetAssistantTurn(id: r.assistantTurnID)
        runStream(userText: r.userText,
                  screenshot: r.screenshot,
                  systemPrompt: r.systemPrompt,
                  history: r.history,
                  assistantTurnID: r.assistantTurnID,
                  wasFirstExchange: false)
    }

    /// Cancel whatever's streaming right now.
    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
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
