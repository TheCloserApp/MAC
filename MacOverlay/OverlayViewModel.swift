import AppKit
import Combine
import EventKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class OverlayViewModel {

    // MARK: - Model catalogue
    static let availableModels: [(id: String, name: String, provider: String)] = [
        ("claude-opus-4-6",           "Opus 4.6",    "Anthropic"),
        ("claude-sonnet-4-6",         "Sonnet 4.6",  "Anthropic"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5",   "Anthropic"),
        ("gpt-4o",                    "GPT-4o",      "OpenAI"),
        ("gpt-4o-mini",               "GPT-4o mini", "OpenAI"),
        ("o3-mini",                   "o3-mini",     "OpenAI"),
    ]

    // MARK: - Session
    var sessionMode: SessionMode = .general {
        didSet {
            UserDefaults.standard.set(sessionMode.rawValue, forKey: "sessionMode")
            scheduleBroadcast()
        }
    }
    var userProfile: UserProfile {
        didSet { UserProfileManager.shared.save(userProfile) }
    }

    // MARK: - Audio / transcription
    var audioSource: AudioSource = .microphone
    var isRecording  = false { didSet { scheduleBroadcast() } }
    var vadEnabled: Bool { didSet { UserDefaults.standard.set(vadEnabled, forKey: "vadEnabled") } }
    var isInterviewSession = false
    var transcription   = "" { didSet { scheduleBroadcast() } }
    var manualInput     = ""
    var showManualInput = false
    var statusMessage   = "" { didSet { scheduleBroadcast() } }

    // MARK: - AI
    var aiResponse     = "" { didSet { scheduleBroadcast() } }
    var isSendingToAI  = false { didSet { scheduleBroadcast() } }
    var pendingQuickAction: QuickAction? = nil
    var pendingScreenshot: NSImage? = nil

    // MARK: - Quick ask (Ctrl+Opt+Q)
    var isQuickAsking     = false
    var quickAskResponse  = ""
    var isQuickAskSending = false

    // MARK: - Option-key dictation
    var isDictating    = false
    var dictationText  = ""

    // MARK: - Notes
    var sessionNotes:  [NoteEntry] = []
    var showNotesPanel = false

    // MARK: - Resume builder
    var showResumeBuilder  = false
    var resumeJD           = ""
    var resumeOutput       = ""
    var resumeFileURL:     URL? = nil
    var isGeneratingResume = false
    /// Live status line shown under the Resume panel's progress bar while
    /// `isGeneratingResume` is true. Updated from the agent loop as Claude
    /// issues each tool call (view / str_replace / insert) so the user
    /// knows what's happening instead of staring at a spinner.
    var resumeGenerationStatus = ""

    // MARK: - Resume score
    var resumeScore:        ResumeScore? = nil
    var isScoringResume     = false

    // MARK: - Embedded browser
    var browserTabs: [BrowserTab] = [] { didSet { scheduleBroadcast() } }
    var activeTabID: UUID? = nil { didSet { scheduleBroadcast() } }
    var splitCount: Int = 1

    var hasBrowser: Bool { !browserTabs.isEmpty }

    func addTab(url: URL = URL(string: "https://www.google.com")!) {
        let tab = BrowserTab(url: url)
        browserTabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(id: UUID) {
        browserTabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = browserTabs.last?.id }
        if browserTabs.isEmpty { splitCount = 1 }
        WebViewRegistry.shared.evict(tabID: id)
    }

    func toggleBrowser() {
        if hasBrowser {
            for tab in browserTabs { WebViewRegistry.shared.evict(tabID: tab.id) }
            browserTabs = []
            activeTabID = nil
            splitCount = 1
        } else {
            addTab()
        }
    }

    /// Navigate the currently active tab to a URL, opening the browser if needed.
    func navigateActiveTab(to url: URL) {
        if !hasBrowser { addTab(url: url); return }
        if let idx = browserTabs.firstIndex(where: { $0.id == activeTabID }) {
            browserTabs[idx].url = url
        } else {
            addTab(url: url)
        }
    }

    /// Switch focus to an existing tab by ID.
    func switchTab(id: UUID) {
        guard browserTabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    // MARK: - Calendar
    var showCalendarPanel = false
    var calendarEvents:   [EKEvent] = []
    var calendarAuthorized = false
    @ObservationIgnored let calendarManager = CalendarManager()

    // MARK: - Settings
    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "anthropicAPIKey") }
    }
    var openAIApiKey: String {
        didSet { UserDefaults.standard.set(openAIApiKey, forKey: "openAIApiKey") }
    }
    var elevenLabsAPIKey: String {
        didSet {
            UserDefaults.standard.set(elevenLabsAPIKey, forKey: "elevenLabsAPIKey")
            transcriptionManager.elevenLabsAPIKey = elevenLabsAPIKey
        }
    }

    /// User-selected transcription backend. `.auto` picks ElevenLabs when a key
    /// is configured and falls back to Apple otherwise; `.apple` and
    /// `.elevenLabs` force the choice regardless of key state.
    enum TranscriptionPreference: String, CaseIterable, Identifiable {
        case auto, apple, elevenLabs
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto:       return "Automatic"
            case .apple:      return "Apple (on-device, free)"
            case .elevenLabs: return "ElevenLabs (cloud)"
            }
        }
    }
    var transcriptionPreference: TranscriptionPreference {
        didSet {
            UserDefaults.standard.set(transcriptionPreference.rawValue,
                                      forKey: "transcriptionPreference")
        }
    }

    /// Which Claude model runs the DOCX `text_editor` tool loop that rewrites
    /// résumés to match a JD. Sonnet 4.5 is the quality default; Haiku 4.5
    /// is ~3× cheaper per run — usually the right choice unless a résumé is
    /// unusually nuanced.
    enum ResumeGenerationModel: String, CaseIterable, Identifiable {
        case sonnet46 = "claude-sonnet-4-6"
        case sonnet45 = "claude-sonnet-4-5"
        case haiku45  = "claude-haiku-4-5-20251001"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .sonnet46: return "Claude Sonnet 4.6 — newest, top quality"
            case .sonnet45: return "Claude Sonnet 4.5 — strong quality"
            case .haiku45:  return "Claude Haiku 4.5 — best value (~3× cheaper)"
            }
        }
    }
    var resumeGenerationModel: ResumeGenerationModel {
        didSet {
            UserDefaults.standard.set(resumeGenerationModel.rawValue,
                                      forKey: "resumeGenerationModel")
        }
    }

    /// How to drive the résumé-tailoring call.
    /// - `.fast`    — single JSON call; Swift does the XML surgery. ~15× cheaper.
    /// - `.hybrid`  — Sonnet analysis (JSON) + Haiku text_editor execution.
    ///                Sonnet-quality edits applied via Claude's tool, ~10×
    ///                cheaper than Quality mode.
    /// - `.quality` — text_editor agent loop end-to-end; Claude plans AND
    ///                verifies each edit live.
    enum ResumeMode: String, CaseIterable, Identifiable {
        case fast, hybrid, quality
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .fast:    return "Fast — single call, ~15× cheaper"
            case .hybrid:  return "Hybrid — Sonnet plan + Haiku apply"
            case .quality: return "Quality — agent loop, best precision"
            }
        }
    }
    var resumeMode: ResumeMode {
        didSet { UserDefaults.standard.set(resumeMode.rawValue, forKey: "resumeMode") }
    }

    /// When true, skip the pre- and post-generation ATS score calls. Saves
    /// ~25% of per-run cost at the cost of not showing a before/after score.
    var resumeSkipScoring: Bool {
        didSet { UserDefaults.standard.set(resumeSkipScoring, forKey: "resumeSkipScoring") }
    }
    var opacity: Double {
        didSet {
            UserDefaults.standard.set(opacity, forKey: "overlayOpacity")
            onOpacityChange?(opacity)
        }
    }
    var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "backgroundOpacity") }
    }
    /// When true, show live token counts in the top strip and per-session.
    var showTokenCounts: Bool {
        didSet { UserDefaults.standard.set(showTokenCounts, forKey: "showTokenCounts") }
    }

    // MARK: - Custom resume prompts

    /// User override for the resume generation system prompt. Empty → use default.
    var customResumeGenerationPrompt: String {
        didSet {
            UserDefaults.standard.set(customResumeGenerationPrompt,
                                      forKey: "customResumeGenerationPrompt")
        }
    }
    /// User override for the resume scoring system prompt. Empty → use default.
    var customResumeScoringPrompt: String {
        didSet {
            UserDefaults.standard.set(customResumeScoringPrompt,
                                      forKey: "customResumeScoringPrompt")
        }
    }

    static let defaultResumeGenerationPrompt =
        "You are an expert resume writer tailoring a resume to a specific job description. Actively rewrite bullets to match the JD's vocabulary and priorities, add new bullets under existing roles when facts elsewhere in the resume support them, and rewrite the summary to pitch the user for THIS role. Keep the section order, heading wording, bullet markers, and capitalisation style identical to the input. Keep every company, job title, location, and date verbatim. Never invent employers, titles, dates, degrees, certifications, metrics, or technologies that aren't already present. Output plain text with no commentary, no markdown fences, no preamble — just the tailored resume."
    static let defaultResumeScoringPrompt =
        "You are an ATS and resume expert. Always respond in the exact format requested."

    /// Resolution order for resume generation:
    /// 1. Active resume-generation preset from the library, if selected.
    /// 2. The plain-text override in Preferences, if non-empty.
    /// 3. The built-in default.
    var resumeGenerationPromptResolved: String {
        if let preset = promptStore.activeResumeGenerationPreset,
           !preset.content.isEmpty {
            return preset.content
        }
        if !customResumeGenerationPrompt.isEmpty {
            return customResumeGenerationPrompt
        }
        return Self.defaultResumeGenerationPrompt
    }
    var resumeScoringPromptResolved: String {
        if let preset = promptStore.activeResumeScoringPreset,
           !preset.content.isEmpty {
            return preset.content
        }
        if !customResumeScoringPrompt.isEmpty {
            return customResumeScoringPrompt
        }
        return Self.defaultResumeScoringPrompt
    }
    /// AppDelegate hooks this to keep the panel's alphaValue in sync.
    @ObservationIgnored var onOpacityChange: ((Double) -> Void)?

    // MARK: - Onboarding
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    var showOnboarding = false

    // MARK: - Libraries + Sessions (enterprise features)
    @ObservationIgnored let promptStore    = PromptStore.shared
    @ObservationIgnored let resumeStore    = ResumeStore.shared
    @ObservationIgnored let sessionStore   = SessionStore.shared
    @ObservationIgnored let workspaceStore = WorkspaceStore.shared

    // UI panel toggles for the new surfaces
    var showHistoryPanel       = false
    var showPromptLibraryPanel = false

    // MARK: - Shell layout (new UX)
    enum PrimarySurface: String, Hashable, CaseIterable, Codable {
        case chat       // live transcript + conversation bubbles (default)
        case sessions   // sessions history list
        case resumes    // resume builder + library
        case prompts    // prompt library
        case calendar
        case browser
        case settings

        var displayName: String {
            switch self {
            case .chat:     return "Chat"
            case .sessions: return "History"
            case .resumes:  return "Resumes"
            case .prompts:  return "Prompts"
            case .calendar: return "Calendar"
            case .browser:  return "Browser"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .chat:     return "bubble.left.and.bubble.right"
            case .sessions: return "clock.arrow.circlepath"
            case .resumes:  return "doc.text"
            case .prompts:  return "text.bubble"
            case .calendar: return "calendar"
            case .browser:  return "globe"
            case .settings: return "gearshape"
            }
        }
        var activeIcon: String {
            switch self {
            case .chat:     return "bubble.left.and.bubble.right.fill"
            case .sessions: return "clock.arrow.circlepath"
            case .resumes:  return "doc.text.fill"
            case .prompts:  return "text.bubble.fill"
            case .calendar: return "calendar"
            case .browser:  return "globe"
            case .settings: return "gearshape.fill"
            }
        }
    }
    /// Which surface is showing in the right column. Nil means no panel is
    /// open — only the sidebar is visible. Clicking a sidebar cell again
    /// while it's active toggles the right column closed.
    var primarySurface: PrimarySurface? = nil
    var sidebarCollapsed: Bool = false

    /// Which corner of the NSPanel the pill is anchored to, based on where
    /// the panel sits relative to the screen. When the pill is near the
    /// right edge, the shell flips so panels appear to its left; when near
    /// the bottom, the shell expands upward. Keeps the UI on-screen no
    /// matter where the user has dragged the overlay.
    enum PillAnchor: String, Hashable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
        var isBottom:   Bool { self == .bottomLeading || self == .bottomTrailing }

        var swiftUIAlignment: Alignment {
            switch self {
            case .topLeading:     return .topLeading
            case .topTrailing:    return .topTrailing
            case .bottomLeading:  return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }

        var unitPoint: UnitPoint {
            switch self {
            case .topLeading:     return .topLeading
            case .topTrailing:    return .topTrailing
            case .bottomLeading:  return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
    }
    var pillAnchor: PillAnchor = .topLeading

    /// True when the full glass shell is showing, false when only the pill
    /// is visible. Lives on the VM so the AppDelegate can hook the NSPanel
    /// frame transition at the exact moment the SwiftUI layout toggles.
    var isShellExpanded: Bool = false {
        didSet { onExpansionChange?(isShellExpanded) }
    }
    @ObservationIgnored var onExpansionChange: ((Bool) -> Void)?

    // MARK: - Peer control
    @ObservationIgnored let peerServer = PeerControlServer.shared
    var peerControlEnabled: Bool {
        didSet {
            UserDefaults.standard.set(peerControlEnabled, forKey: "peerControlEnabled")
            if peerControlEnabled { peerServer.start() } else { peerServer.stop() }
        }
    }
    /// Staging area for messages the peer wants to send — shown to the local user
    /// for review before going to AI.  Empty = nothing pending.
    var peerMessage: String = "" { didSet { scheduleBroadcast() } }

    @ObservationIgnored let transcriptionManager = TranscriptionManager()
    @ObservationIgnored let appleTranscriber    = AppleTranscriber()

    /// Which transcription engine is being used right now. Switches live with
    /// whether the user has configured an ElevenLabs key.
    enum TranscriptionBackend: String { case elevenLabs = "ElevenLabs", apple = "Apple" }
    var transcriptionBackend: TranscriptionBackend {
        switch transcriptionPreference {
        case .apple:      return .apple
        case .elevenLabs: return elevenLabsAPIKey.isEmpty ? .apple : .elevenLabs
        case .auto:       return elevenLabsAPIKey.isEmpty ? .apple : .elevenLabs
        }
    }

    /// Start transcription using whichever backend is active.
    private func startTranscriber(source: AudioSource) async throws {
        switch transcriptionBackend {
        case .elevenLabs: try await transcriptionManager.start(source: source)
        case .apple:      try await appleTranscriber.start(source: source)
        }
    }

    /// Stop whichever backend happens to be running.
    private func stopTranscriber() {
        if transcriptionManager.isRunning { transcriptionManager.stop() }
        if appleTranscriber.isRunning    { appleTranscriber.stop() }
    }
    @ObservationIgnored private let quickRecorder   = QuickRecorder.shared
    @ObservationIgnored let notesManager            = NotesManager.shared
    @ObservationIgnored private let reminderManager = ReminderManager.shared
    @ObservationIgnored private var cancellables    = Set<AnyCancellable>()
    @ObservationIgnored private var calendarRefreshTimer: AnyCancellable?
    @ObservationIgnored private var broadcastTask: Task<Void, Never>?

    /// Owns all AI-streaming logic (send, retry, title regen). Initialised lazily
    /// so `self` is fully constructed before the controller captures it.
    @ObservationIgnored lazy var ai: AIController         = AIController(vm: self)
    @ObservationIgnored lazy var resume: ResumeController = ResumeController(vm: self)

    /// True when the latest assistant turn is a recoverable error and a retry
    /// is available. Views key off this to surface the Retry button.
    var canRetryLastResponse: Bool { ai.canRetry }

    /// Debounced peer broadcast. Replaces the Combine throttle pipeline that
    /// previously merged 9 publishers.
    private func scheduleBroadcast() {
        broadcastTask?.cancel()
        broadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.peerServer.broadcastState()
        }
    }

    init() {
        // NOTE: didSet observers do NOT fire during init for properties set on `self`,
        // so initial values are loaded without triggering UserDefaults writes or broadcasts.
        vadEnabled         = UserDefaults.standard.bool(forKey: "vadEnabled")
        apiKey             = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        openAIApiKey       = UserDefaults.standard.string(forKey: "openAIApiKey") ?? ""
        elevenLabsAPIKey   = UserDefaults.standard.string(forKey: "elevenLabsAPIKey") ?? ""
        transcriptionPreference = TranscriptionPreference(
            rawValue: UserDefaults.standard.string(forKey: "transcriptionPreference") ?? ""
        ) ?? .auto
        // Default to Haiku 4.5 — most résumé rewrites don't need Sonnet's
        // extra reasoning, and the 3× cost difference is substantial.
        resumeGenerationModel = ResumeGenerationModel(
            rawValue: UserDefaults.standard.string(forKey: "resumeGenerationModel") ?? ""
        ) ?? .haiku45
        // Default to fast mode — real-time, ~15× cheaper than agent loop.
        resumeMode = ResumeMode(
            rawValue: UserDefaults.standard.string(forKey: "resumeMode") ?? ""
        ) ?? .fast
        resumeSkipScoring = UserDefaults.standard.bool(forKey: "resumeSkipScoring")
        selectedModel      = UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-sonnet-4-6"
        opacity            = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 1.0
        backgroundOpacity  = UserDefaults.standard.object(forKey: "backgroundOpacity") as? Double ?? 1.0
        showTokenCounts    = UserDefaults.standard.bool(forKey: "showTokenCounts")
        customResumeGenerationPrompt =
            UserDefaults.standard.string(forKey: "customResumeGenerationPrompt") ?? ""
        customResumeScoringPrompt =
            UserDefaults.standard.string(forKey: "customResumeScoringPrompt") ?? ""
        userProfile        = UserProfileManager.shared.load()
        peerControlEnabled = UserDefaults.standard.bool(forKey: "peerControlEnabled")
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if let raw = UserDefaults.standard.string(forKey: "sessionMode"),
           let mode = SessionMode(rawValue: raw) {
            sessionMode = mode
        }

        // Calendar manager still exposes Combine publishers; keep these subscriptions.
        calendarManager.$upcomingEvents
            .sink { [weak self] in self?.calendarEvents = $0 }.store(in: &cancellables)
        calendarManager.$isAuthorized
            .sink { [weak self] in self?.calendarAuthorized = $0 }.store(in: &cancellables)

        // Refresh calendar every 5 minutes
        calendarRefreshTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.calendarManager.refresh() }
            }

        // Connect peer server to self and start if previously enabled
        peerServer.viewModel = self
        if peerControlEnabled { peerServer.start() }

        // Sessions created before workspaces existed need to inherit the
        // default workspace so they still show up in the list.
        sessionStore.migrateWorkspacelessSessions(to: workspaceStore.activeWorkspaceID)

        transcriptionManager.elevenLabsAPIKey = elevenLabsAPIKey

        let updateHandler: (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in self?.transcription = text }
        }
        transcriptionManager.onUpdate = updateHandler
        appleTranscriber.onUpdate    = updateHandler

        let silenceHandler: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.transcription.isEmpty else { return }

                // Quick ask is handled by QuickRecorder (SFSpeechRecognizer) — ignore here
                if self.isQuickAsking { return }

                guard self.isRecording else { return }

                if self.isInterviewSession {
                    // Continuous mode: stop engine, send segment, clear, restart
                    guard !self.isSendingToAI else { return }
                    self.stopTranscriber()
                    self.isRecording = false
                    self.statusMessage = ""

                    self.sendToAI()          // captures transcription before we clear
                    self.transcription = ""

                    // Restart after a short pause (lets mic settle)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard self.isInterviewSession else { return }
                    do {
                        try await self.startTranscriber(source: self.audioSource)
                        self.isRecording = true
                        self.statusMessage = "Recording"
                    } catch {
                        self.statusMessage = "Error: \(error.localizedDescription)"
                        self.isInterviewSession = false
                    }
                } else if self.vadEnabled {
                    self.toggleRecording()
                    self.sendToAI()
                }
            }
        }
        transcriptionManager.onSilence = silenceHandler
        appleTranscriber.onSilence    = silenceHandler
    }

    // MARK: - Calendar

    func requestCalendarAccess() {
        Task {
            let granted = await calendarManager.requestAccess()
            if granted {
                await scheduleReminders()
                _ = await ReminderManager.shared.requestPermission()
            }
        }
    }

    private func scheduleReminders() async {
        reminderManager.cancelAllReminders()
        for event in calendarEvents {
            reminderManager.scheduleReminder(for: event, minutesBefore: 15, profile: userProfile)
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopTranscriber()
            isRecording   = false
            statusMessage = ""
        } else {
            transcription = ""
            aiResponse    = ""
            statusMessage = "Starting…"
            Task {
                do {
                    try await startTranscriber(source: audioSource)
                    isRecording   = true
                    statusMessage = ""
                } catch {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isRecording   = false
                }
            }
        }
    }

    // MARK: - Hotkey record toggle (Ctrl+Opt+M)

    func hotkeyToggleRecord() {
        if isInterviewSession { stopInterviewSession(); return }
        if isRecording {
            stopTranscriber()
            isRecording   = false
            statusMessage = ""
            if !transcription.isEmpty { sendToAI() }
        } else {
            transcription = ""
            aiResponse    = ""
            statusMessage = "Starting…"
            Task {
                do {
                    try await startTranscriber(source: audioSource)
                    isRecording   = true
                    statusMessage = ""
                } catch {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isRecording   = false
                }
            }
        }
    }

    // MARK: - Interview session

    func startInterviewSession() {
        guard !isInterviewSession else { return }
        isInterviewSession = true
        transcription = ""
        aiResponse    = ""
        guard !isRecording else { return }
        statusMessage = "Starting…"
        Task {
            do {
                try await startTranscriber(source: audioSource)
                isRecording   = true
                statusMessage = ""
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
                isInterviewSession = false
                isRecording = false
            }
        }
    }

    func stopInterviewSession() {
        isInterviewSession = false
        if isRecording {
            stopTranscriber()
            isRecording   = false
            statusMessage = ""
        }
    }

    // MARK: - Quick actions

    func selectQuickAction(_ action: QuickAction) {
        pendingQuickAction = action
        if !transcription.isEmpty || !manualInput.isEmpty { sendToAI() }
    }

    // MARK: - AI

    /// Called by the local user to forward the peer's staged message to AI.
    func sendPeerMessageToAI() {
        guard !peerMessage.isEmpty else { return }
        manualInput     = peerMessage
        showManualInput = true
        peerMessage     = ""
        sendToAI()
    }

    func sendToAI() {
        let baseText   = showManualInput && !manualInput.isEmpty ? manualInput : transcription
        let prefix     = pendingQuickAction.map { $0.promptPrefix } ?? ""
        let textToSend = prefix + baseText

        guard !textToSend.isEmpty || pendingScreenshot != nil else { return }

        let isOpenAI = AIManager.shared.isOpenAIModel(selectedModel)
        if  isOpenAI && openAIApiKey.isEmpty { return }
        if !isOpenAI && apiKey.isEmpty       { return }

        let resolvedPrompt   = resolveActivePrompt()
        let historySnapshot  = sessionStore.replayContext()

        let wasFirstExchange = sessionStore.activeSession.turns.isEmpty
        sessionStore.appendUser(textToSend)
        let assistantID = sessionStore.beginStreamingAssistant()

        if !showManualInput { transcription = "" }

        let snapshot = pendingScreenshot
        pendingQuickAction = nil
        if showManualInput { manualInput = "" }
        pendingScreenshot = nil

        ai.runStream(userText: textToSend,
                     screenshot: snapshot,
                     systemPrompt: resolvedPrompt,
                     history: historySnapshot,
                     assistantTurnID: assistantID,
                     wasFirstExchange: wasFirstExchange)
    }

    /// Retry the most recent failed request.
    func retryLastResponse() { ai.retry() }

    /// Reset an assistant turn to empty so a fresh stream can populate it.
    func resetAssistantTurn(id: UUID) {
        var s = sessionStore.activeSession
        guard let idx = s.turns.firstIndex(where: { $0.id == id }) else { return }
        s.turns[idx].content = ""
        s.turns[idx].inputTokens = nil
        s.turns[idx].outputTokens = nil
        sessionStore.activeSession = s
    }

    /// Cancel an in-flight streaming request.
    func cancelStreaming() { ai.cancel() }

    /// Resolves the current system prompt. Kept as a shim so existing
    /// call-sites don't have to change — delegates to the AI controller.
    func resolveActivePrompt() -> String { ai.resolveActivePrompt() }

    // MARK: - Quick ask

    func toggleQuickAsk() {
        if isQuickAskSending { return }

        if isQuickAsking {
            // Stop → hand off to Apple STT for final transcript
            isQuickAsking = false
            statusMessage = "Processing…"
            quickRecorder.stopAndTranscribe { [weak self] text in
                guard let self else { return }
                self.statusMessage = ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.sendQuickAskToAI(text: trimmed)
            }
        } else {
            quickAskResponse = ""
            isQuickAsking    = true
            statusMessage    = "Listening…"
            Task {
                _ = await quickRecorder.requestPermission()
                do {
                    try quickRecorder.start()
                } catch {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isQuickAsking = false
                }
            }
        }
    }

    func dismissQuickAsk() {
        if isQuickAsking {
            quickRecorder.stopAndTranscribe { _ in }   // discard
            isQuickAsking = false
            statusMessage = ""
        }
        quickAskResponse  = ""
        isQuickAskSending = false
    }

    private func sendQuickAskToAI(text: String) {
        let isOpenAI = AIManager.shared.isOpenAIModel(selectedModel)
        if  isOpenAI && openAIApiKey.isEmpty { quickAskResponse = "No API key configured."; return }
        if !isOpenAI && apiKey.isEmpty       { quickAskResponse = "No API key configured."; return }

        isQuickAskSending = true
        quickAskResponse  = ""

        let resolvedPrompt  = resolveActivePrompt()
        let historySnapshot = sessionStore.replayContext()

        // Stream into quickAskResponse and also into a session turn so it's
        // recorded in history.
        sessionStore.appendUser(text)
        let assistantID = sessionStore.beginStreamingAssistant()

        Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = AIManager.shared.streamMessage(
                    text,
                    apiKey:       self.apiKey,
                    openAIApiKey: self.openAIApiKey,
                    model:        self.selectedModel,
                    screenshot:   nil,
                    systemPrompt: resolvedPrompt,
                    history:      historySnapshot
                )
                for try await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        accumulated += chunk
                        self.quickAskResponse = accumulated
                        self.sessionStore.appendChunk(chunk, to: assistantID)
                    case .usage(let inTok, let outTok):
                        self.sessionStore.finalizeAssistant(turnID: assistantID,
                                                            inputTokens: inTok,
                                                            outputTokens: outTok)
                    }
                }
                if !accumulated.isEmpty {
                    self.notesManager.add(content: accumulated, source: .ai, mode: self.sessionMode)
                    self.sessionNotes = self.notesManager.entries
                }
            } catch {
                self.quickAskResponse = "Error: \(error.localizedDescription)"
            }
            self.isQuickAskSending = false
        }
    }

    // MARK: - Notes

    func saveNoteManually(_ text: String) {
        guard !text.isEmpty else { return }
        notesManager.add(content: text, source: .manual, mode: sessionMode)
        sessionNotes = notesManager.entries
    }

    func clearNotes() {
        notesManager.clear()
        sessionNotes = []
    }

    // MARK: - Session actions (wired to UI)

    // MARK: - Export

    func copyActiveSessionAsMarkdown() {
        let md = sessionStore.markdown(for: sessionStore.activeSession)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        statusMessage = "Session copied as Markdown"
        // Auto-clear status after a moment
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self?.statusMessage == "Session copied as Markdown" {
                self?.statusMessage = ""
            }
        }
    }

    func exportActiveSessionToDisk() {
        let session = sessionStore.activeSession
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.displayTitle).md"
        panel.title = "Export session as Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sessionStore.markdown(for: session)
                .write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func continueSession(id: UUID) {
        sessionStore.continueSession(id: id)
        // Restore the mode for the reopened session so the right prompt kicks in.
        if let s = sessionStore.sessions.first(where: { $0.id == id }) {
            sessionMode = s.mode
            promptStore.activePresetID = s.promptPresetID
        }
        // Jump the UI back to the chat view so the reopened session is visible.
        primarySurface = .chat
    }

    func startNewSession() {
        // Before closing the current session, ask the AI to give it a nicer title.
        let closingID = sessionStore.activeSessionID
        let closing = sessionStore.activeSession
        sessionStore.startNewSession(mode: sessionMode,
                                     promptPresetID: promptStore.activePresetID,
                                     workspaceID: workspaceStore.activeWorkspaceID)
        regenerateTitle(for: closing, sessionID: closingID)
        primarySurface = .chat
    }

    // MARK: - Workspaces

    /// Switch to a workspace. If the current session belongs to a different
    /// workspace, try to pick the most recent session in the target workspace,
    /// otherwise start a fresh session there.
    func switchWorkspace(to id: UUID) {
        workspaceStore.activeWorkspaceID = id
        let scoped = sessionStore.sortedSessions(in: id)
        if let first = scoped.first {
            sessionStore.continueSession(id: first.id)
        } else {
            sessionStore.startNewSession(mode: sessionMode,
                                         promptPresetID: promptStore.activePresetID,
                                         workspaceID: id)
        }
        primarySurface = .chat
    }

    func addWorkspace(name: String, icon: String, colorHex: String) {
        let w = workspaceStore.add(name: name, icon: icon, colorHex: colorHex)
        switchWorkspace(to: w.id)
    }

    func deleteWorkspace(id: UUID) {
        workspaceStore.delete(id: id) { [weak self] old, new in
            self?.sessionStore.reassignSessions(from: old, to: new)
        }
    }

    /// Kicks off a background title regeneration via the AI controller.
    private func regenerateTitle(for session: ChatSession, sessionID: UUID) {
        ai.regenerateTitle(for: session, sessionID: sessionID)
    }

    func exportNotes(asMarkdown: Bool) {
        do {
            let url = asMarkdown
                ? try notesManager.exportAsMarkdown()
                : try notesManager.exportAsPlainText()
            NSWorkspace.shared.open(url)
        } catch {
            print("Export failed: \(error)")
        }
    }

    // MARK: - Resume builder

    // Called by hotkey: reads clipboard as JD, uses the active resume preset
    func generateResumeFromClipboard() {
        guard let jd = NSPasteboard.general.string(forType: .string), !jd.isEmpty else { return }
        resumeJD      = jd
        showResumeBuilder = true
        generateResume()
    }

    /// Content of the currently selected resume preset.
    var currentResumeText: String {
        resumeStore.activePreset?.content ?? ""
    }

    // Called by hotkey: scores current resume against clipboard JD
    func scoreResumeFromClipboard() {
        guard let jd = NSPasteboard.general.string(forType: .string), !jd.isEmpty else { return }
        resume.score(jd: jd)
    }

    func generateResume() { resume.generate() }

    // MARK: - Helpers

    var canSend: Bool {
        let hasText = showManualInput ? !manualInput.isEmpty : !transcription.isEmpty
        let isOpenAI = AIManager.shared.isOpenAIModel(selectedModel)
        let hasKey   = isOpenAI ? !openAIApiKey.isEmpty : !apiKey.isEmpty
        return (hasText || pendingScreenshot != nil) && !isSendingToAI && hasKey
    }

    var needsKeyForCurrentModel: Bool {
        AIManager.shared.isOpenAIModel(selectedModel) ? openAIApiKey.isEmpty : apiKey.isEmpty
    }
}
