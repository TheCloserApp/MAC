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
    /// Full catalogue of models the app can route requests to. The model
    /// picker filters this list against `ModelVisibility.shared` so users
    /// can hide models they don't use without losing them — flipping the
    /// switch in Settings → AI brings any of them back instantly.
    /// Routing: ids prefixed `gpt-` / `o1` / `o3` / `o4` go through the
    /// OpenAI path (see `AIManager.isOpenAIModel`); everything else goes
    /// to Anthropic.
    static let availableModels: [(id: String, name: String, provider: String)] = [
        // Anthropic
        ("claude-opus-4-7",           "Opus 4.7",        "Anthropic"),
        ("claude-opus-4-6",           "Opus 4.6",        "Anthropic"),
        ("claude-sonnet-4-6",         "Sonnet 4.6",      "Anthropic"),
        ("claude-sonnet-4-5",         "Sonnet 4.5",      "Anthropic"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5",       "Anthropic"),
        // OpenAI — frontier
        ("gpt-4o",                    "GPT-4o",          "OpenAI"),
        ("gpt-4o-mini",               "GPT-4o mini",     "OpenAI"),
        ("gpt-4.1",                   "GPT-4.1",         "OpenAI"),
        ("gpt-4.1-mini",              "GPT-4.1 mini",    "OpenAI"),
        ("gpt-4-turbo",               "GPT-4 Turbo",     "OpenAI"),
        // OpenAI — reasoning
        ("o3",                        "o3",              "OpenAI"),
        ("o3-mini",                   "o3-mini",         "OpenAI"),
        ("o1",                        "o1",              "OpenAI"),
        ("o1-mini",                   "o1-mini",         "OpenAI"),
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
    var audioSource: AudioSource = .microphone {
        didSet {
            NSLog("[OverlayViewModel] audioSource changed: %@ -> %@",
                  oldValue.label, audioSource.label)
            applyBrowserAudioRouting()
        }
    }
    /// Holds an error message when BlackHole routing failed (e.g. driver not
    /// installed). The browser panel watches this to show a non-modal banner.
    var browserAudioRouterError: String? = nil
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

    // MARK: - Interview setup (pre-Start form on the Interview surface)
    /// Optional resume the user uploaded for the upcoming interview. The file
    /// is read once at Start time and prepended to the interview's context
    /// payload; we hold the URL so the form can display the filename.
    var interviewResumeFileURL: URL? = nil
    /// Free-text context describing the role, company, JD, etc. Empty = none.
    var interviewContext: String = ""
    /// Which past session the user picked to resume. `nil` means "New session".
    var interviewResumeSessionID: UUID? = nil

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
    /// Mirrors `BrowserAudioRouter.shared.isRouting` so SwiftUI views can
    /// reflect the routing state without observing CoreAudio directly.
    var browserSystemAudioRouting: Bool = false
    /// Whether the macOS default *output* device is configured so that
    /// audio actually reaches BlackHole. The browser banner uses this to
    /// warn the user when System mode is on but their output device won't
    /// produce any signal for the website to read.
    var browserSystemOutputState: BrowserAudioRouter.SystemOutputState = .notRouted

    var hasBrowser: Bool { !browserTabs.isEmpty }

    func addTab(url: URL = URL(string: "https://www.google.com")!) {
        let tab = BrowserTab(url: url)
        browserTabs.append(tab)
        activeTabID = tab.id
        applyBrowserAudioRouting()
    }

    func closeTab(id: UUID) {
        browserTabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = browserTabs.last?.id }
        if browserTabs.isEmpty {
            splitCount = 1
        }
        WebViewRegistry.shared.evict(tabID: id)
        applyBrowserAudioRouting()
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
        applyBrowserAudioRouting()
    }

    /// Called by the browser's audio-source picker. Mirrors `audioSource` for
    /// transcription, and additionally — when the user picks `.systemAudio`
    /// — redirects the macOS default *input* device to BlackHole so any
    /// website inside the embedded browser receives system audio through its
    /// `getUserMedia` mic stream. Reverts the device when switching back.
    /// Returns nil on success, or an error description for the UI to show.
    @discardableResult
    func setBrowserAudioSource(_ src: AudioSource) -> String? {
        // Setting audioSource triggers applyBrowserAudioRouting via didSet,
        // which fills in browserAudioRouterError. Mirror it back so existing
        // call sites that ignore the property still get a return value.
        audioSource = src
        return browserAudioRouterError
    }

    /// Reconciles the BlackHole router state with the current
    /// `(audioSource, hasBrowser)` pair. Called from `audioSource.didSet`,
    /// `toggleBrowser`, `closeTab`, and `addTab` so any change to either
    /// input recomputes the right routing decision.
    private func applyBrowserAudioRouting() {
        let shouldRoute     = hasBrowser && audioSource == .systemAudio
        let wasRouting      = browserSystemAudioRouting
        NSLog("[OverlayViewModel] applyBrowserAudioRouting: hasBrowser=%@ audioSource=%@ -> shouldRoute=%@",
              hasBrowser ? "true" : "false",
              audioSource.label,
              shouldRoute ? "true" : "false")

        if shouldRoute {
            do {
                try BrowserAudioRouter.shared.enable()
                browserSystemAudioRouting = true
                browserAudioRouterError   = nil
            } catch {
                browserSystemAudioRouting = false
                browserAudioRouterError   = error.localizedDescription
                NSLog("[OverlayViewModel] BlackHole enable failed: %@",
                      error.localizedDescription)
            }
        } else {
            BrowserAudioRouter.shared.disable()
            browserSystemAudioRouting = false
            browserAudioRouterError   = nil
        }

        // Refresh the cached output state on any routing change. The
        // CoreAudio listener handles user-driven changes (Output picker,
        // Audio MIDI Setup) but firing here covers the case where the user
        // just toggled the source and we want the banner up immediately.
        browserSystemOutputState = BrowserAudioRouter.shared.currentSystemOutputState()

        // Webpages cache `MediaStream` against the device that was current at
        // capture time, so the only way to make a running tab pick up the
        // new default input is a hard reload. We only reload when routing
        // *changed* — switching off `.systemAudio` back to mic, or vice
        // versa — so we don't churn pages on no-op reconciles.
        if wasRouting != browserSystemAudioRouting && hasBrowser {
            NSLog("[OverlayViewModel] routing changed (%@ -> %@); reloading browser tabs",
                  wasRouting ? "on" : "off",
                  browserSystemAudioRouting ? "on" : "off")
            WebViewRegistry.shared.reloadAll()
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

    // MARK: - Auth + entitlements
    /// Shared singletons exposed on the VM so SwiftUI views can observe them
    /// via `@Bindable`. The stores stay singletons because they hold
    /// process-wide state (Keychain bindings) — only the VM proxy is per-instance.
    let auth        = AuthManager.shared
    let entitlement = EntitlementStore.shared
    let quota       = ResumeQuotaTracker.shared

    // MARK: - Panel customization
    /// User-customisable visibility + sizing for the lower input bar.
    /// Toggles persist to UserDefaults via the store itself.
    let barCustomization = BarCustomization.shared

    /// True when a paywall sheet should be visible. Flipped by quota gates
    /// (e.g. ResumeController.generate() when the free user is at their cap).
    var showPaywall: Bool = false

    // UI panel toggles for the new surfaces
    var showHistoryPanel       = false
    var showPromptLibraryPanel = false

    // MARK: - Shell layout (new UX)
    enum PrimarySurface: String, Hashable, CaseIterable, Codable {
        case chat       // live transcript + conversation bubbles (default)
        case interview  // interview setup + live interview surface
        case sessions   // sessions history list
        case resumes    // resume builder + library
        case prompts    // prompt library
        case calendar
        case browser
        case settings

        var displayName: String {
            switch self {
            case .chat:      return "Chat"
            case .interview: return "Interview"
            case .sessions:  return "History"
            case .resumes:   return "Resumes"
            case .prompts:   return "Prompts"
            case .calendar:  return "Calendar"
            case .browser:   return "Browser"
            case .settings:  return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .chat:      return "bubble.left.and.bubble.right"
            case .interview: return "person.fill.checkmark"
            case .sessions:  return "clock.arrow.circlepath"
            case .resumes:   return "doc.text"
            case .prompts:   return "text.bubble"
            case .calendar:  return "calendar"
            case .browser:   return "globe"
            case .settings:  return "gearshape"
            }
        }
        var activeIcon: String {
            switch self {
            case .chat:      return "bubble.left.and.bubble.right.fill"
            case .interview: return "person.fill.checkmark"
            case .sessions:  return "clock.arrow.circlepath"
            case .resumes:   return "doc.text.fill"
            case .prompts:   return "text.bubble.fill"
            case .calendar:  return "calendar"
            case .browser:   return "globe"
            case .settings:  return "gearshape.fill"
            }
        }
    }
    /// Which surface is showing inside the expanded shell. `nil` means
    /// the shell is in the bar-only (compact) layout — replaces the old
    /// `.composer` shell stage. Clicking a surface button again while
    /// it's active toggles back to nil.
    var primarySurface: PrimarySurface? = nil {
        didSet {
            if oldValue != primarySurface {
                onPrimarySurfaceChange?(primarySurface)
            }
        }
    }
    @ObservationIgnored var onPrimarySurfaceChange: ((PrimarySurface?) -> Void)?
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

    /// Two-stage shell. Either the collapsed pill is on screen, or the
    /// full overlay panel is. Within `.expanded` the layout adapts to
    /// `primarySurface`:
    ///   - `primarySurface == nil` → just the input bar (compact).
    ///   - `primarySurface != nil` → top card (title + body) + input bar.
    ///
    /// User transitions:
    ///   pill → expanded   (hover or click the brand logo)
    ///   expanded → pill   (click the collapse button on the bar)
    ///   any expanded ↔ expanded surface change (click sidebar buttons)
    enum ShellStage: String, Equatable {
        case pill, expanded

        var isOnScreen: Bool { self == .expanded }
    }

    var shellStage: ShellStage = .pill {
        didSet {
            if oldValue != shellStage {
                onShellStageChange?(shellStage)
            }
        }
    }
    @ObservationIgnored var onShellStageChange: ((ShellStage) -> Void)?

    /// Backward-compat read-only shim. New code should test
    /// `shellStage == .expanded` directly.
    var isShellExpanded: Bool { shellStage == .expanded }

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

        // Bind the per-user stores to whoever is currently signed in (or the
        // anonymous bucket if nobody is). The AuthGateView will trigger a
        // re-bind once the user signs in / out via `bindUserScopedStores()`.
        bindUserScopedStores()

        // Calendar manager still exposes Combine publishers; keep these
        // subscriptions wired so the manager keeps compiling, but skip the
        // 5-minute refresh timer when the calendar feature is hidden in v1
        // — no point burning a Timer + EventKit access for UI no user sees.
        if FeatureFlags.calendarEnabled {
            calendarManager.$upcomingEvents
                .sink { [weak self] in self?.calendarEvents = $0 }.store(in: &cancellables)
            calendarManager.$isAuthorized
                .sink { [weak self] in self?.calendarAuthorized = $0 }.store(in: &cancellables)

            calendarRefreshTimer = Timer.publish(every: 300, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { await self?.calendarManager.refresh() }
                }
        }

        // Connect peer server to self and start if previously enabled.
        // Gated so v1 doesn't even bind a port if the user had peer enabled
        // in a prior build; the underlying setting is preserved for v2.
        peerServer.viewModel = self
        if FeatureFlags.peerControlEnabled && peerControlEnabled {
            peerServer.start()
        }

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

        // Track the system output device so the browser banner can warn
        // the user when System mode is on but BlackHole isn't actually
        // receiving any audio (e.g. output is set to plain speakers).
        browserSystemOutputState = BrowserAudioRouter.shared.currentSystemOutputState()
        BrowserAudioRouter.shared.onSystemOutputStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.browserSystemOutputState = state
            }
        }
    }

    // MARK: - Auth lifecycle

    /// Re-bind entitlement + quota to the current user ID. Called on init and
    /// whenever the auth state changes (sign-in, sign-out, switch to guest)
    /// so the right Keychain bucket is in scope.
    func bindUserScopedStores() {
        let id = auth.currentUser?.userID
        entitlement.bind(to: id)
        quota.bind(to: id)
    }

    /// Sign out + re-bind to the anonymous bucket. Called from the Account
    /// tab in Preferences.
    func signOut() {
        auth.signOut()
        bindUserScopedStores()
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

    /// Kick off an interview from the Interview surface's setup form. Picks
    /// either a fresh session or the user-selected past one, seeds it with
    /// the optional resume + context, sets the mode to .interview, and
    /// starts the live recording.
    func beginInterviewFromSetup() {
        sessionMode = .interview

        if let pickedID = interviewResumeSessionID,
           sessionStore.sessions.contains(where: { $0.id == pickedID }) {
            continueSession(id: pickedID)
        } else {
            startNewSession()
        }

        // Seed the session with the user's setup context so the AI knows what
        // role/JD/resume backs this interview. Skipped silently when both are
        // empty — no point adding a noise turn.
        let resumeText = readInterviewResumeText()
        let trimmedContext = interviewContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resumeText.isEmpty || !trimmedContext.isEmpty {
            var seed = "[Interview setup]\n"
            if !trimmedContext.isEmpty {
                seed += "\nContext:\n\(trimmedContext)\n"
            }
            if !resumeText.isEmpty {
                let name = interviewResumeFileURL?.lastPathComponent ?? "resume"
                seed += "\nAttached resume (\(name)):\n\(resumeText)\n"
            }
            manualInput = seed
            showManualInput = true
        }

        startInterviewSession()
    }

    /// Reads the user-selected resume file as plain text using the existing
    /// resume importer (covers pdf/docx/rtf/txt/md). Returns "" on failure.
    private func readInterviewResumeText() -> String {
        guard let url = interviewResumeFileURL else { return "" }
        return (try? ResumeImporter.importFile(url: url)) ?? ""
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

        // Sending a message implies the user wants to see the response.
        // Promote the shell to the full expanded chat surface so the
        // streaming assistant turn appears in the top panel — even if the
        // user kicked the send off from the collapsed pill (voice
        // transcription, quick-ask, or just the bar).
        primarySurface = .chat
        if shellStage != .expanded {
            withAnimation(Design.Motion.spring) {
                shellStage = .expanded
            }
        }

        let wasFirstExchange = sessionStore.activeSession.turns.isEmpty
        sessionStore.appendUser(textToSend)
        let assistantID = sessionStore.beginStreamingAssistant(model: selectedModel)

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
        let assistantID = sessionStore.beginStreamingAssistant(model: selectedModel)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            var lastFlush = ContinuousClock.now
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
                        self.sessionStore.appendChunk(chunk, to: assistantID)
                        let now = ContinuousClock.now
                        if now - lastFlush >= .milliseconds(33) {
                            self.quickAskResponse = accumulated
                            lastFlush = now
                        }
                    case .usage(let inTok, let outTok):
                        self.sessionStore.finalizeAssistant(turnID: assistantID,
                                                            inputTokens: inTok,
                                                            outputTokens: outTok)
                    }
                }
                if self.quickAskResponse != accumulated {
                    self.quickAskResponse = accumulated
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
