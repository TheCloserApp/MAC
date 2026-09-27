import Foundation
import Observation

/// Owns all chat sessions. Every send/response is recorded as a turn on the
/// `activeSession`. New sessions are started explicitly via `startNewSession()`.
@Observable
@MainActor
final class SessionStore {
    static let shared = SessionStore()
    private static let filename = "sessions.json"

    var sessions: [ChatSession] {
        didSet { schedulePersist() }
    }
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    var activeSessionID: UUID {
        didSet {
            UserDefaults.standard.set(activeSessionID.uuidString, forKey: "activeSessionID")
        }
    }

    /// If enabled, the active session's prior turns are sent as context on the
    /// next AI request. If disabled, each request is stateless (no memory carry).
    var memorySyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(memorySyncEnabled, forKey: "memorySyncEnabled")
        }
    }

    /// If enabled, the last turn-pair from each of the 3 most recently updated
    /// *other* sessions is also included as context. Good for continuity across
    /// interviews/calls on the same topic. Off by default (privacy + cost).
    var crossSessionMemoryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(crossSessionMemoryEnabled, forKey: "crossSessionMemoryEnabled")
        }
    }

    /// How many prior turn-pairs from the active session to replay as context.
    /// Ignored when `memoryIncludeAll` is true.
    var memoryWindow: Int {
        didSet {
            UserDefaults.standard.set(memoryWindow, forKey: "memoryWindow")
        }
    }
    /// When true, include the ENTIRE active session regardless of `memoryWindow`.
    var memoryIncludeAll: Bool {
        didSet {
            UserDefaults.standard.set(memoryIncludeAll, forKey: "memoryIncludeAll")
        }
    }

    /// How many prior sessions to pull one turn-pair from, when cross-session is on.
    var crossSessionWindow: Int {
        didSet {
            UserDefaults.standard.set(crossSessionWindow, forKey: "crossSessionWindow")
        }
    }

    private init() {
        let loaded = JSONStore.load([ChatSession].self, from: Self.filename) ?? []
        let restoredActiveID: UUID? = {
            guard let raw = UserDefaults.standard.string(forKey: "activeSessionID"),
                  let uuid = UUID(uuidString: raw),
                  loaded.contains(where: { $0.id == uuid })
            else { return nil }
            return uuid
        }()

        // If nothing restored, spin up a fresh session.
        if loaded.isEmpty || restoredActiveID == nil {
            let fresh = ChatSession()
            self.sessions = loaded + [fresh]
            self.activeSessionID = fresh.id
        } else {
            self.sessions = loaded
            self.activeSessionID = restoredActiveID!
        }

        self.memorySyncEnabled         = UserDefaults.standard.object(forKey: "memorySyncEnabled") as? Bool ?? true
        self.crossSessionMemoryEnabled = UserDefaults.standard.object(forKey: "crossSessionMemoryEnabled") as? Bool ?? false
        self.memoryWindow              = UserDefaults.standard.object(forKey: "memoryWindow") as? Int ?? 6
        self.memoryIncludeAll          = UserDefaults.standard.object(forKey: "memoryIncludeAll") as? Bool ?? false
        self.crossSessionWindow        = UserDefaults.standard.object(forKey: "crossSessionWindow") as? Int ?? 3
    }

    /// Back to the memory defaults above. TheCloser Pro uses these and hides
    /// the Memory settings.
    func useDefaultMemorySettings() {
        memorySyncEnabled = true
        crossSessionMemoryEnabled = false
        memoryWindow = 6
        memoryIncludeAll = false
        crossSessionWindow = 3
    }

    // MARK: - Active session helpers

    var activeSession: ChatSession {
        get { sessions.first { $0.id == activeSessionID } ?? sessions[0] }
        set {
            guard let idx = sessions.firstIndex(where: { $0.id == newValue.id }) else { return }
            sessions[idx] = newValue
        }
    }

    /// Appends a user turn + assistant turn to the active session, updating
    /// title on first real message.
    func appendTurn(user: String, assistant: String) {
        appendUser(user)
        appendAssistant(assistant)
    }

    /// Append only a user turn — used by the chat surface so the message
    /// appears immediately, before the AI has responded. `hiddenContext`
    /// carries the full attachment text that was sent to the AI but kept
    /// out of the visible bubble, so later requests can replay it.
    func appendUser(_ content: String,
                    attachments: [String] = [],
                    hiddenContext: String? = nil) {
        var s = activeSession
        s.turns.append(ChatTurn(role: .user,
                                content: content,
                                attachments: attachments.isEmpty ? nil : attachments,
                                hiddenContext: hiddenContext))
        s.updatedAt = Date()
        if s.title.isEmpty {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                s.title = String(trimmed.prefix(48))
            } else if let first = attachments.first {
                s.title = first
            }
        }
        activeSession = s
    }

    /// Append an assistant turn. Called after the AI response arrives.
    func appendAssistant(_ content: String) {
        var s = activeSession
        s.turns.append(ChatTurn(role: .assistant, content: content))
        s.updatedAt = Date()
        activeSession = s
    }

    /// Append an empty assistant turn, return its ID. Used by the streaming
    /// path — the caller then pushes chunks and eventually usage tokens into
    /// it via `appendChunk` / `finalize`.
    @discardableResult
    func beginStreamingAssistant(model: String? = nil) -> UUID {
        var s = activeSession
        let turn = ChatTurn(role: .assistant, content: "", model: model)
        s.turns.append(turn)
        s.updatedAt = Date()
        activeSession = s
        return turn.id
    }

    /// Append streaming text to a specific assistant turn.
    func appendChunk(_ chunk: String, to turnID: UUID) {
        var s = activeSession
        guard let idx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[idx].content += chunk
        s.updatedAt = Date()
        activeSession = s
    }

    /// Replace a streaming assistant turn's content wholesale. The
    /// streaming path batches chunks and flushes at ~30Hz through this —
    /// every mutation here copies the session value and invalidates every
    /// observer (plus re-parses the markdown for the growing turn), so
    /// per-token appends made long answers render visibly slower the
    /// longer they got.
    func setStreamingContent(_ content: String, turnID: UUID) {
        var s = activeSession
        guard let idx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[idx].content = content
        // No updatedAt bump here: it changes sort keys 30×/sec during a
        // stream, invalidating History and every date-sorted observer for
        // no reason. begin/finalize stamp it.
        activeSession = s
    }

    /// Replace streaming content for a turn in a specific session
    /// (Quick Ask path).
    func setStreamingContent(_ content: String, turnID: UUID, in sessionID: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var s = sessions[sIdx]
        guard let tIdx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[tIdx].content = content
        sessions[sIdx] = s
    }

    /// Attach token usage to an assistant turn.
    func finalizeAssistant(turnID: UUID, inputTokens: Int, outputTokens: Int) {
        var s = activeSession
        guard let idx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[idx].inputTokens  = inputTokens
        s.turns[idx].outputTokens = outputTokens
        s.updatedAt = Date()
        activeSession = s
    }

    /// Context to replay on the next AI request, respecting both memory toggles.
    /// Order: recent cross-session pairs first, then current-session pairs last,
    /// so the LLM weights the current thread highest.
    func replayContext() -> [(user: String, assistant: String)] {
        guard memorySyncEnabled else { return [] }
        let currentPairs = pairs(from: activeSession)
        var sliced = memoryIncludeAll ? currentPairs : Array(currentPairs.suffix(memoryWindow))

        // Size budget on the rolling window. Interview answers are long
        // and detailed, so re-sending the last N of them on every turn is
        // what makes replies feel slower the deeper a session runs — the
        // input prompt keeps growing. Trim the window to a character
        // budget, dropping the OLDEST recent pairs first so the latest
        // exchanges always survive. The resume/context anchor below is
        // added AFTER, so it's never trimmed away. `memoryIncludeAll` is
        // an explicit "send everything" override — respect it untouched.
        if !memoryIncludeAll {
            sliced = trimmedToBudget(sliced, budget: Self.recentContextBudget)
        }

        // Anchor the session's opening exchange: it carries the setup
        // context (resume, JD, interview brief) that the whole session
        // leans on. Without this, a long interview silently loses its
        // grounding once the first pair slides out of the window.
        if !memoryIncludeAll,
           let first = currentPairs.first,
           currentPairs.count > memoryWindow {
            sliced = [first] + sliced
        }

        guard crossSessionMemoryEnabled else { return sliced }

        let others = sortedSessions
            .filter { $0.id != activeSessionID && !$0.turns.isEmpty }
            .prefix(crossSessionWindow)

        let crossPairs: [(String, String)] = others.compactMap { pairs(from: $0).last }
        return crossPairs + sliced
    }

    /// Character budget for the rolling recent-history window — roughly
    /// 12k chars ≈ 3k tokens, a handful of recent exchanges. Excludes the
    /// resume/context anchor and the system prompt, which ride on top.
    private static let recentContextBudget = 12_000

    /// Keep the most recent pairs that fit inside `budget` characters,
    /// walking newest → oldest. The latest pair is always kept even if it
    /// alone blows the budget, so the model never loses the question it's
    /// answering.
    private func trimmedToBudget(_ pairs: [(String, String)],
                                 budget: Int) -> [(String, String)] {
        var kept: [(String, String)] = []
        var total = 0
        for pair in pairs.reversed() {
            let cost = pair.0.count + pair.1.count
            if !kept.isEmpty, total + cost > budget { break }
            kept.append(pair)
            total += cost
        }
        return kept.reversed()
    }

    private func pairs(from session: ChatSession) -> [(String, String)] {
        var out: [(String, String)] = []
        var i = 0
        let turns = session.turns
        while i < turns.count - 1 {
            if turns[i].role == .user, turns[i + 1].role == .assistant {
                let user      = turns[i].replayText
                let assistant = turns[i + 1].content
                // Skip pairs with an empty side — a cancelled stream leaves
                // an empty assistant turn, and the API rejects empty content.
                if !user.isEmpty && !assistant.isEmpty {
                    out.append((user, assistant))
                }
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: - CRUD

    func startNewSession(mode: SessionMode = .general,
                         promptPresetID: UUID? = nil,
                         workspaceID: UUID? = nil,
                         kind: ChatSession.Kind = .normal) {
        let fresh = ChatSession(kind: kind,
                                mode: mode,
                                promptPresetID: promptPresetID,
                                workspaceID: workspaceID)
        sessions.append(fresh)
        activeSessionID = fresh.id
    }

    /// Creates a quick-ask session without taking over the user's active
    /// session pointer. Quick asks need their own history entry but the
    /// user is usually in the middle of another chat/interview — switching
    /// active would disrupt that surface, so the caller (Quick Ask flow)
    /// drives this directly and writes turns by ID.
    @discardableResult
    func createQuickAskSession(workspaceID: UUID?) -> UUID {
        let fresh = ChatSession(kind: .quickAsk,
                                mode: .general,
                                workspaceID: workspaceID)
        sessions.append(fresh)
        return fresh.id
    }

    /// Append a user turn to a specific session by ID (used by Quick Ask so
    /// it doesn't mutate the user's currently-active session).
    func appendUser(to sessionID: UUID, _ content: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var s = sessions[idx]
        s.turns.append(ChatTurn(role: .user, content: content))
        s.updatedAt = Date()
        if s.title.isEmpty {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { s.title = String(trimmed.prefix(48)) }
        }
        sessions[idx] = s
    }

    /// Begin an assistant streaming turn against a specific session.
    @discardableResult
    func beginStreamingAssistant(in sessionID: UUID, model: String? = nil) -> UUID {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return UUID() }
        var s = sessions[idx]
        let turn = ChatTurn(role: .assistant, content: "", model: model)
        s.turns.append(turn)
        s.updatedAt = Date()
        sessions[idx] = s
        return turn.id
    }

    /// Append streaming text to a specific assistant turn within a specific
    /// session (Quick Ask path).
    func appendChunk(_ chunk: String, to turnID: UUID, in sessionID: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var s = sessions[sIdx]
        guard let tIdx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[tIdx].content += chunk
        s.updatedAt = Date()
        sessions[sIdx] = s
    }

    /// Finalize an assistant turn's token counts within a specific session.
    func finalizeAssistant(turnID: UUID, in sessionID: UUID,
                            inputTokens: Int, outputTokens: Int) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var s = sessions[sIdx]
        guard let tIdx = s.turns.firstIndex(where: { $0.id == turnID }) else { return }
        s.turns[tIdx].inputTokens  = inputTokens
        s.turns[tIdx].outputTokens = outputTokens
        s.updatedAt = Date()
        sessions[sIdx] = s
    }

    /// Sessions scoped to a given workspace, most-recent first.
    func sortedSessions(in workspaceID: UUID) -> [ChatSession] {
        sortedSessions.filter { $0.workspaceID == workspaceID }
    }

    /// Reassigns sessions from one workspace to another (used when a workspace
    /// is deleted). Preserves session history.
    func reassignSessions(from oldID: UUID, to newID: UUID) {
        for i in sessions.indices where sessions[i].workspaceID == oldID {
            sessions[i].workspaceID = newID
        }
    }

    /// Ensures every session has a workspace. Called once at app launch —
    /// legacy sessions saved before workspaces existed get auto-assigned to
    /// the given fallback.
    func migrateWorkspacelessSessions(to fallback: UUID) {
        var changed = false
        for i in sessions.indices where sessions[i].workspaceID == nil {
            sessions[i].workspaceID = fallback
            changed = true
        }
        if changed { schedulePersist() }
    }

    func continueSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
    }

    func delete(id: UUID) {
        // Never leave ourselves without an active session.
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            let fresh = ChatSession()
            sessions.append(fresh)
            activeSessionID = fresh.id
        } else if activeSessionID == id {
            activeSessionID = sessions.last!.id
        }
    }

    func clearAll() {
        sessions.removeAll()
        let fresh = ChatSession()
        sessions.append(fresh)
        activeSessionID = fresh.id
    }

    /// Toggle the pinned flag on a session. Pinned sessions float to the top
    /// of History regardless of date.
    func togglePin(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        sessions[idx].updatedAt = Date()
    }

    /// Manual rename by the user: locks the title so auto-retitle won't overwrite.
    func rename(id: UUID, to newTitle: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = newTitle
        sessions[idx].titleManuallySet = true
        sessions[idx].updatedAt = Date()
    }

    /// Assigns an AI-generated title but only if the user hasn't renamed the
    /// session themselves. Intended for post-completion retitling.
    func setAutoTitle(id: UUID, to generated: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard !sessions[idx].titleManuallySet else { return }
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[idx].title = trimmed
        sessions[idx].updatedAt = Date()
    }

    var sortedSessions: [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Export

    /// Render a session as Markdown. User turns become `## You`, assistant
    /// turns become `## AI` with preserved markdown body. Suitable for copy
    /// to clipboard or save to disk.
    func markdown(for session: ChatSession) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var out = "# \(session.displayTitle)\n\n"
        out += "_\(session.mode.displayName) session · \(df.string(from: session.createdAt))_\n\n"
        for turn in session.turns {
            switch turn.role {
            case .user:
                out += "## You\n\n\(turn.content)\n\n"
            case .assistant:
                out += "## AI\n\n\(turn.content)\n\n"
            case .system:
                continue
            }
        }
        return out
    }

    /// Writes the Markdown to a temp file and returns the URL so callers can
    /// offer a Save… sheet or open it in an editor.
    func exportMarkdownFile(for session: ChatSession) throws -> URL {
        let safeTitle = session.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(50)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle).md")
        try markdown(for: session).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Persistence

    /// Coalesces rapid mutations (e.g. token-by-token streaming appends)
    /// into a single disk write per ~400ms quiet window. Without this,
    /// every chunk during a streaming response wrote the entire session
    /// JSON to disk — visible UI stutter on long answers.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        JSONStore.save(sessions, to: Self.filename)
    }

    /// Flush any pending debounced write immediately. Called on app
    /// terminate so we don't lose the last chunk of a stream that ended
    /// inside the debounce window. The barrier matters: `persist()` only
    /// *enqueues* an async write, and the process exiting first would
    /// silently drop it.
    func flushPendingPersist() {
        persistTask?.cancel()
        persistTask = nil
        persist()
        JSONStore.flush()
    }
}
