import AppKit
import AVFoundation
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
        ("claude-fable-5",            "Fable 5",         "Anthropic"),
        ("claude-opus-4-8",           "Opus 4.8",        "Anthropic"),
        ("claude-opus-4-7",           "Opus 4.7",        "Anthropic"),
        ("claude-opus-4-6",           "Opus 4.6",        "Anthropic"),
        ("claude-sonnet-4-6",         "Sonnet 4.6",      "Anthropic"),
        ("claude-sonnet-4-5",         "Sonnet 4.5",      "Anthropic"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5",       "Anthropic"),
        // OpenAI — frontier
        ("gpt-5",                     "GPT-5",           "OpenAI"),
        ("gpt-5-mini",                "GPT-5 mini",      "OpenAI"),
        ("gpt-5-nano",                "GPT-5 nano",      "OpenAI"),
        ("gpt-4.5-preview",           "GPT-4.5",         "OpenAI"),
        ("gpt-4.1",                   "GPT-4.1",         "OpenAI"),
        ("gpt-4.1-mini",              "GPT-4.1 mini",    "OpenAI"),
        ("gpt-4.1-nano",              "GPT-4.1 nano",    "OpenAI"),
        ("gpt-4o",                    "GPT-4o",          "OpenAI"),
        ("gpt-4o-mini",               "GPT-4o mini",     "OpenAI"),
        ("gpt-4-turbo",               "GPT-4 Turbo",     "OpenAI"),
        // OpenAI — reasoning
        ("o3-pro",                    "o3-pro",          "OpenAI"),
        ("o3",                        "o3",              "OpenAI"),
        ("o3-mini",                   "o3-mini",         "OpenAI"),
        ("o4-mini",                   "o4-mini",         "OpenAI"),
        ("o1-pro",                    "o1-pro",          "OpenAI"),
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
            guard oldValue != audioSource else { return }
            NSLog("[OverlayViewModel] audioSource changed: %@ -> %@",
                  oldValue.label, audioSource.label)
            applyBrowserAudioRouting()
            // Mid-session switch: restart the engine on the new source so
            // the picker takes effect immediately instead of on next start.
            if isRecording { restartCaptureForNewSource() }
        }
    }
    /// Holds an error message when BlackHole routing failed (e.g. driver not
    /// installed). The browser panel watches this to show a non-modal banner.
    var browserAudioRouterError: String? = nil
    var isRecording  = false { didSet { scheduleBroadcast() } }
    var vadEnabled: Bool { didSet { UserDefaults.standard.set(vadEnabled, forKey: "vadEnabled") } }
    var isInterviewSession = false
    /// Interview is active but recording is paused. The transcriber is
    /// stopped so audio stops flowing, but the session, transcript, and
    /// context all stay intact so resuming picks up cleanly.
    var isInterviewPaused  = false
    /// True when the live session is text-only (Regular call → Chat mode).
    /// The bar swaps the pause button for a send button and never starts
    /// the mic; everything else (Stop, model picker) behaves the same.
    var isInterviewTextOnly = false
    /// When the current running phase of the interview started. Nil
    /// while paused. The on-screen timer reads
    /// `interviewElapsedSeconds + (now - this)` so it survives
    /// pause/resume cycles instead of resetting to 0 every time.
    var interviewRunningSince: Date? = nil
    /// Total seconds accumulated across previous running phases of this
    /// interview. Pausing flushes the current phase into this number;
    /// resuming starts a new phase.
    var interviewElapsedSeconds: TimeInterval = 0
    var transcription   = "" {
        didSet {
            // Any flow that clears the strip (send, new session, filter
            // drop) intends a fresh start — drop queued committed segments
            // with it so they can't resurface in the next compose.
            if transcription.isEmpty {
                committedBacklog      = ""
                lastPartialNormalized = ""
            }
            scheduleBroadcast()
        }
    }
    /// Normalized form of the last partial that cancelled the pending
    /// auto-send. Engines re-emit text with revised punctuation/casing
    /// after the speaker stops — only a SUBSTANTIVE change (new words)
    /// should reset the auto-send debounce, or cosmetic revisions delay
    /// the answer by an unpredictable amount.
    @ObservationIgnored private var lastPartialNormalized = ""

    /// Cancel the pending debounced auto-send — but only when the new
    /// partial actually contains different words than the one that armed
    /// the cancel last time.
    private func cancelAutoSendIfNewSpeech(_ text: String) {
        let norm = TranscriptFilter.normalized(text)
        guard norm != lastPartialNormalized else { return }
        lastPartialNormalized = norm
        pendingAutoSendTask?.cancel()
    }
    /// Committed-but-unsent ElevenLabs segments. Scribe partials describe
    /// only the *current* utterance, so without this backlog every new
    /// sentence would erase the previous one from the strip — and any
    /// question asked while the AI was still streaming was silently lost.
    /// Apple doesn't need it (its recognition text accumulates per task).
    @ObservationIgnored private var committedBacklog = ""
    /// Pending debounced auto-send (see scheduleAutoSend). Cancelled the
    /// moment new speech arrives so a mid-question VAD commit never fires
    /// the AI on half a question.
    @ObservationIgnored private var pendingAutoSendTask: Task<Void, Never>?
    var manualInput     = ""
    var showManualInput = false
    var statusMessage   = "" { didSet { scheduleBroadcast() } }

    // MARK: - AI
    var aiResponse     = "" { didSet { scheduleBroadcast() } }
    var isSendingToAI  = false { didSet { scheduleBroadcast() } }
    var pendingQuickAction: QuickAction? = nil
    var pendingScreenshot: NSImage? = nil
    /// File attachments queued for the next outgoing message. The full
    /// extracted text is sent to the AI as part of the prompt, but only
    /// the file names are stored on the user's `ChatTurn` — keeps the
    /// chat from being flooded with imported document text.
    var pendingAttachments: [PendingAttachment] = []

    struct PendingAttachment: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let extractedText: String
    }

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
    /// Optional resume the user uploaded for the upcoming interview. We hold
    /// the URL so the form can display the filename — and the moment it's
    /// set we kick off `prepareInterviewResumeText()` so the (potentially
    /// slow) PDF/DOCX parse happens in the background BEFORE Start, not as a
    /// blocking step the instant the user wants to begin.
    var interviewResumeFileURL: URL? = nil {
        didSet {
            guard interviewResumeFileURL != oldValue else { return }
            prepareInterviewResumeText()
        }
    }
    /// Resume text pre-extracted at pick time (see `prepareInterviewResumeText`).
    /// `readInterviewResumeText()` uses this so Start is instant.
    private(set) var interviewResumeText: String = ""
    /// True while the picked resume is being parsed in the background — lets
    /// the setup form show a "Reading…" hint instead of looking idle.
    private(set) var isPreparingResume = false
    /// Free-text context describing the role, company, JD, etc. Empty = none.
    var interviewContext: String = ""
    /// Which past session the user picked to resume. `nil` means "New session".
    var interviewResumeSessionID: UUID? = nil
    /// Extra context files (JD PDF, notes, briefing docs, etc.). Their text
    /// is extracted once at the form and rides as a pending attachment on
    /// the interview's first user turn — same treatment as the resume.
    var interviewContextFiles: [InterviewContextFile] = []
    /// When ON, the AI auto-streams suggested responses as the interview
    /// transcript updates. When OFF, the user hits Send manually. Only
    /// shown / honored in `.interview` setup; Regular call has no such
    /// toggle today.
    var interviewAutoGenerate: Bool = true

    /// Live Focus: during a live interview, show only the current question
    /// and the latest streaming answer instead of the full conversation —
    /// everything that isn't the current exchange melts away. Toggleable
    /// from the live strip; resets to ON each time a session goes live.
    var interviewFocusMode: Bool = true

    /// Whether the live transcript strip is visible during an interview.
    /// Hiding it leaves ONLY the question + answer on screen; the toggle
    /// lives in the session ⋯ menu. Resets to visible per live session.
    var showLiveTranscript: Bool = true

    /// Two modes the Interview surface can host: a full interview (resume
    /// + JD + transcription) or a lighter Regular call (just system
    /// prompt + context, with a Call/Chat sub-toggle).
    enum InterviewSurfaceMode: String, Equatable, CaseIterable {
        case interview, regularCall

        var displayName: String {
            switch self {
            case .interview:   return "Interview"
            case .regularCall: return "Regular call"
            }
        }
        var icon: String {
            switch self {
            case .interview:   return "person.fill.checkmark"
            case .regularCall: return "phone.bubble.fill"
            }
        }
        var sessionKind: ChatSession.Kind {
            switch self {
            case .interview:   return .interview
            case .regularCall: return .regularCall
            }
        }
    }

    /// Which mode tab is selected on the Interview surface. Drives both
    /// the setup form on display and which "most recent session" to
    /// auto-resume when the user clicks the surface icon.
    var interviewSurfaceMode: InterviewSurfaceMode = .interview
    /// Set true when the user clicks the `+ new session` button while on
    /// the Interview surface — forces the setup form to render even when
    /// a recent session of the active mode exists. Cleared when Start is
    /// hit (a real session begins) or when the surface is dismissed.
    var forceInterviewSetup: Bool = false

    /// Whether a Regular call setup should kick off a live (mic) session
    /// or just a text-only chat session. Mirrors the user's last choice
    /// across launches.
    var regularCallAsCall: Bool = true

    struct InterviewContextFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let name: String
        let extractedText: String
    }

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
            // Mid-session engine switch (⋯ menu): restart capture so the
            // new backend takes over immediately, like the source picker.
            if oldValue != transcriptionPreference, isRecording {
                restartCaptureForNewSource()
            }
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

    /// True when shellStage is `.pill` AND a result/status popup wants to
    /// render above the brand pill (resume score, generated resume,
    /// quick-ask response). AppDelegate listens via `onPillPopupChange`
    /// to grow the host panel just enough to fit the popup.
    var hasPillPopup: Bool {
        guard shellStage == .pill else { return false }
        return isScoringResume || isGeneratingResume || resumeScore != nil
            || resumeFileURL != nil || isQuickAskSending
            || !quickAskResponse.isEmpty
    }
    @ObservationIgnored var onPillPopupChange: ((Bool) -> Void)?

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

        // Apple delivers one growing string per recognition task, so the
        // raw update can replace the live transcript wholesale. New text =
        // the speaker is still going — cancel any pending auto-send so we
        // never answer half a question.
        appleTranscriber.onUpdate = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelAutoSendIfNewSpeech(text)
                self.transcription = text
            }
        }

        // ElevenLabs is per-utterance: partials describe only the current
        // utterance and would erase earlier sentences. Accumulate committed
        // segments in `committedBacklog` and compose the display — same
        // pattern DictationManager uses for hold-to-dictate. A fresh
        // partial means the speaker resumed → cancel any pending auto-send;
        // the next commit reschedules it with the fuller transcript.
        transcriptionManager.onPartial = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelAutoSendIfNewSpeech(text)
                self.transcription = self.committedBacklog.isEmpty
                    ? text
                    : self.committedBacklog + " " + text
            }
        }
        transcriptionManager.onCommit = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.committedBacklog = self.committedBacklog.isEmpty
                        ? trimmed
                        : self.committedBacklog + " " + trimmed
                }
                if !self.committedBacklog.isEmpty {
                    self.transcription = self.committedBacklog
                }
            }
        }

        // Engine/connection failures land in the status line, not the
        // transcript — an error string in the strip used to get auto-sent
        // to the AI as if the interviewer had said it.
        let errorHandler: (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in self?.statusMessage = message }
        }
        transcriptionManager.onError = errorHandler
        appleTranscriber.onError     = errorHandler

        // Audio capture self-healing: when the input device disappears
        // mid-session (AirPods die, headset unplugged) or the system-audio
        // stream stops, the engine halts silently — restart capture on
        // whatever device is current. The 400ms settle gives CoreAudio
        // time to re-resolve the default device; the epoch system makes
        // user actions during that window win over this recovery.
        let interruptionHandler: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                // Debounce: device flapping can fire config-change
                // notifications in bursts — one recovery per window.
                guard Date().timeIntervalSince(self.lastCaptureRecoveryAt) > 1.5 else { return }
                self.lastCaptureRecoveryAt = Date()
                self.statusMessage = "Reconnecting audio…"
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard self.isRecording else { return }
                _ = await self.beginCapture(statusWhileStarting: "Reconnecting audio…")
            }
        }
        transcriptionManager.onCaptureInterrupted = interruptionHandler
        appleTranscriber.onCaptureInterrupted     = interruptionHandler

        // Transient connection drops self-heal (the manager reconnects with
        // backoff); the user just sees a status line flip while it happens.
        transcriptionManager.onConnectionEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .reconnecting:
                    self.statusMessage = "Reconnecting transcription…"
                case .reconnected:
                    // Clear BOTH the transient "Reconnecting…" line and the
                    // louder connection-lost error — the manager keeps
                    // retrying after reporting .failed, so a late recovery
                    // must wipe the stale error too.
                    if self.statusMessage == "Reconnecting transcription…"
                        || self.statusMessage.hasPrefix("Error: Transcription connection lost") {
                        self.statusMessage = ""
                    }
                case .failed(let message):
                    self.statusMessage = "Error: \(message)"
                }
            }
        }

        let silenceHandler: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.transcription.isEmpty else { return }

                // Quick ask is handled by QuickRecorder (SFSpeechRecognizer) — ignore here
                if self.isQuickAsking { return }

                guard self.isRecording else { return }

                if self.isInterviewSession {
                    // Continuous mode: send the committed segment and keep
                    // listening. Honors the "Auto-generate responses" toggle
                    // on the Interview setup — when OFF, the transcript
                    // stays accumulating until the user hits Send manually.
                    guard self.interviewAutoGenerate else { return }
                    // Don't fire the AI on noise / filler-only commits
                    // ("um", coughs, [noise] the engine hallucinated). Drop
                    // the segment so it doesn't linger in the transcript and
                    // keep listening.
                    guard TranscriptFilter.isMeaningful(self.transcription) else {
                        self.transcription = ""
                        return
                    }
                    // A response is still streaming and a NEW question just
                    // committed: the latest question wins. Cancel the
                    // in-flight answer and let the debounced send pick up
                    // the new one — waiting for the old answer to finish
                    // made the app feel deaf mid-interview. Echo check
                    // first so the user reading the streaming answer
                    // aloud doesn't kill their own answer.
                    if self.isSendingToAI {
                        let lastAnswer = self.sessionStore.activeSession.turns
                            .last(where: { $0.role == .assistant })?.content ?? ""
                        if TranscriptFilter.echoesAnswer(self.transcription, answer: lastAnswer) {
                            self.transcription = ""   // read-along — drop it
                            return
                        }
                        self.cancelStreaming()
                    }
                    // Debounced: a VAD commit isn't proof the question is
                    // over. scheduleAutoSend waits a short grace window
                    // (longer when the text trails off mid-thought) and
                    // is cancelled by any new speech.
                    self.scheduleAutoSend()
                } else if self.vadEnabled {
                    // Skip noise / filler-only segments so VAD auto-send
                    // doesn't ship junk to the AI; keep listening.
                    guard TranscriptFilter.isMeaningful(self.transcription) else { return }
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

    // MARK: - Capture lifecycle (epoch-protected)

    /// Monotonic token for the audio-capture lifecycle. Every transition
    /// (start, stop, pause, resume, source switch) bumps it; async
    /// continuations capture the value when they begin and abort if it
    /// no longer matches. Without this, a pause issued while a start was
    /// still in flight let the stale start finish and turn the mic back
    /// on — recording silently continued under a "Paused" UI.
    @ObservationIgnored private var captureEpoch = 0

    /// App Nap suppression while capture runs. Hours-long interviews sit
    /// in the background from macOS's perspective (the overlay never
    /// becomes the active app), and App Nap throttles timers + I/O of
    /// napping processes — which surfaced as transcription stalls deep
    /// into long sessions.
    @ObservationIgnored private var captureActivity: NSObjectProtocol?
    /// Last time the capture self-recovery ran (device-change handler).
    @ObservationIgnored private var lastCaptureRecoveryAt = Date.distantPast

    private enum CaptureStartResult { case started, superseded, failed }

    /// Start capture on the current `audioSource`. Always tears down any
    /// running engine first so two engines can never overlap. If another
    /// transition happens while the engine is starting, this start loses:
    /// the engine is shut straight back down and `.superseded` is returned
    /// so callers don't mutate session state that the newer transition owns.
    @discardableResult
    private func beginCapture(statusWhileStarting: String = "Starting…") async -> CaptureStartResult {
        captureEpoch += 1
        let epoch = captureEpoch
        stopTranscriber()
        isRecording   = false
        statusMessage = statusWhileStarting
        do {
            try await startTranscriber(source: audioSource)
            guard epoch == captureEpoch else {
                stopTranscriber()
                return .superseded
            }
            isRecording   = true
            statusMessage = ""
            if captureActivity == nil {
                captureActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Live transcription session")
            }
            return .started
        } catch {
            guard epoch == captureEpoch else { return .superseded }
            NSLog("[Capture] start failed: %@", error.localizedDescription)
            statusMessage = "Error: \(error.localizedDescription)"
            isRecording   = false
            return .failed
        }
    }

    /// Stop capture and invalidate every in-flight start, restart, and
    /// pending auto-send.
    private func endCapture(status: String = "") {
        captureEpoch += 1
        pendingAutoSendTask?.cancel()
        stopTranscriber()
        isRecording   = false
        statusMessage = status
        if let activity = captureActivity {
            ProcessInfo.processInfo.endActivity(activity)
            captureActivity = nil
        }
    }

    /// Live audio-source switch: restart the engine on the new source
    /// without touching session state. Before this, the picker only took
    /// effect on the NEXT start — switching mic ↔ system mid-interview
    /// silently kept capturing the old source.
    private func restartCaptureForNewSource() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.beginCapture(
                statusWhileStarting: "Switching to \(self.audioSource.label)…")
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            endCapture()
        } else {
            transcription = ""
            aiResponse    = ""
            Task { @MainActor [weak self] in
                _ = await self?.beginCapture()
            }
        }
    }

    // MARK: - Hotkey record toggle (Ctrl+Opt+M)

    func hotkeyToggleRecord() {
        if isInterviewSession { stopInterviewSession(); return }
        if isRecording {
            endCapture()
            if !transcription.isEmpty { sendToAI() }
        } else {
            transcription = ""
            aiResponse    = ""
            Task { @MainActor [weak self] in
                _ = await self?.beginCapture()
            }
        }
    }

    // MARK: - Interview session

    func startInterviewSession() {
        NSLog("[Interview] startInterviewSession: audioSource=%@ backend=%@",
              audioSource.label, transcriptionBackend.rawValue)
        guard !isInterviewSession else {
            NSLog("[Interview] guarded — already in session")
            return
        }
        isInterviewSession = true
        isInterviewPaused  = false
        interviewFocusMode = true
        showLiveTranscript = true
        transcription = ""
        aiResponse    = ""
        // Fresh start — reset the elapsed counter and begin a new
        // running phase so the on-screen timer ticks from 00:00.
        interviewElapsedSeconds = 0
        interviewRunningSince   = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.beginCapture()
            if case .failed = result {
                // Mic never came up — don't leave a zombie "live" session.
                self.isInterviewSession   = false
                self.interviewRunningSince = nil
            }
        }
    }

    func stopInterviewSession() {
        isInterviewSession  = false
        isInterviewPaused   = false
        isInterviewTextOnly = false
        interviewRunningSince   = nil
        interviewElapsedSeconds = 0
        endCapture()
    }

    /// Pause an active interview: stop audio capture but keep the session
    /// alive so the user can resume without losing transcript / context.
    /// Folds the current running phase into `interviewElapsedSeconds` so
    /// the timer holds at its current value instead of resetting on the
    /// next resume.
    func pauseInterviewSession() {
        guard isInterviewSession, !isInterviewPaused else { return }
        if let started = interviewRunningSince {
            interviewElapsedSeconds += Date().timeIntervalSince(started)
        }
        interviewRunningSince = nil
        isInterviewPaused     = true

        // Stop audio capture first so nothing is transcribed while paused.
        // endCapture bumps the epoch, so a start that's still in flight
        // (rapid play→pause) can't bring the mic back up underneath us.
        endCapture(status: "Paused")

        // Treat the pause like a silence boundary: commit whatever transcript
        // has accumulated and turn it into one AI response. Unlike the
        // auto-generate silence handler we do NOT restart afterwards — we stay
        // paused. Skip if the user has a manual draft in the bar (don't hijack
        // their typed text) or a request is already in flight.
        let pending = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty, TranscriptFilter.isMeaningful(pending),
           !isSendingToAI, !showManualInput {
            sendToAI()            // captures `transcription`, then clears it
        }

        statusMessage = "Paused"
    }

    /// Resume a paused interview by restarting the transcriber and
    /// opening a new running phase — the existing elapsed time is kept
    /// so the timer continues from where it paused.
    func resumeInterviewSession() {
        guard isInterviewSession, isInterviewPaused else { return }
        // Text-only sessions have no microphone to resume — flipping the
        // paused flag is all "play" means there.
        guard !isInterviewTextOnly else { return }
        isInterviewPaused = false
        interviewRunningSince = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.beginCapture(statusWhileStarting: "Resuming…")
            if case .failed = result {
                self.isInterviewPaused = true
                self.interviewRunningSince = nil
            }
        }
    }

    /// Kick off an interview from the Interview surface's setup form. Picks
    /// either a fresh session or the user-selected past one, seeds it with
    /// the optional resume + context, sets the mode to .interview, and
    /// starts the live recording.
    func beginInterviewFromSetup() {
        sessionMode = .interview
        forceInterviewSetup = false

        if let pickedID = interviewResumeSessionID,
           sessionStore.sessions.contains(where: { $0.id == pickedID }) {
            continueSession(id: pickedID, stayInPrimarySurface: true)
        } else {
            startNewSession(kind: .interview, stayInPrimarySurface: true)
        }

        // Seed the next outgoing message with the user's setup context so
        // the AI knows what role/JD/resume backs this interview. Context,
        // resume, and extra files all ride as pending attachments on the
        // first send — the AI receives the full text as labelled blocks
        // while the chat bubble only shows chips. Staging the context in
        // the manual-input draft (the old approach) made the first silence
        // boundary send the context INSTEAD of the interviewer's opening
        // question, which was then dropped.
        let resumeText     = readInterviewResumeText()
        let trimmedContext = interviewContext.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedContext.isEmpty {
            pendingAttachments.append(
                PendingAttachment(name: "Interview context", extractedText: trimmedContext)
            )
        }

        if !resumeText.isEmpty {
            let name = interviewResumeFileURL?.lastPathComponent ?? "resume"
            pendingAttachments.append(
                PendingAttachment(name: name, extractedText: resumeText)
            )
        }

        for ctx in interviewContextFiles where !ctx.extractedText.isEmpty {
            pendingAttachments.append(
                PendingAttachment(name: ctx.name, extractedText: ctx.extractedText)
            )
        }
        // Consumed — clear so the next interview setup starts clean.
        interviewContextFiles = []

        startInterviewSession()
    }

    /// Resume text for the interview payload. Prefers the copy we already
    /// extracted in the background when the file was picked; only falls back
    /// to a synchronous read if Start somehow beat the background parse (or
    /// it failed), so we never start an interview missing the resume.
    private func readInterviewResumeText() -> String {
        guard let url = interviewResumeFileURL else { return "" }
        if !interviewResumeText.isEmpty { return interviewResumeText }
        return (try? ResumeImporter.importFile(url: url)) ?? ""
    }

    /// Parse the picked resume off the main thread and cache the text in
    /// `interviewResumeText`. Called automatically when `interviewResumeFileURL`
    /// changes, so by the time the user hits Start the text is usually ready
    /// and the interview begins without a parse stall.
    private func prepareInterviewResumeText() {
        interviewResumeText = ""
        guard let url = interviewResumeFileURL else {
            isPreparingResume = false
            return
        }
        isPreparingResume = true
        Task.detached(priority: .userInitiated) {
            let text = (try? ResumeImporter.importFile(url: url)) ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop a stale result if the user swapped or cleared the
                // file while this parse was still in flight.
                guard self.interviewResumeFileURL == url else { return }
                self.interviewResumeText = text
                self.isPreparingResume = false
            }
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
        // Any explicit send supersedes a pending debounced auto-send —
        // without this a manual Send followed by the grace-window firing
        // would double-send the same transcript.
        pendingAutoSendTask?.cancel()
        let baseText   = showManualInput && !manualInput.isEmpty ? manualInput : transcription
        let prefix     = pendingQuickAction.map { $0.promptPrefix } ?? ""
        let userText   = prefix + baseText

        let attachments    = pendingAttachments
        let hasAttachments = !attachments.isEmpty

        guard !userText.isEmpty || pendingScreenshot != nil || hasAttachments else { return }

        // Missing key: tell the user instead of silently dropping the
        // message. The "Error" prefix makes the status row render even
        // mid-interview, where regular status text is suppressed.
        let isOpenAI = AIManager.shared.isOpenAIModel(selectedModel)
        if (isOpenAI && openAIApiKey.isEmpty) || (!isOpenAI && apiKey.isEmpty) {
            statusMessage = "Error: no \(isOpenAI ? "OpenAI" : "Anthropic") API key — add it in Profile → API keys, or pick another model."
            return
        }

        let resolvedPrompt   = resolveActivePrompt()
        let historySnapshot  = sessionStore.replayContext()

        // What the AI receives: file contents prepended as labelled blocks
        // so the model knows what each chunk is, followed by the user's
        // typed text. What the chat UI displays: only the user's text
        // alongside chips for each attachment — no flood of document body.
        // The blocks are also stored on the turn as `hiddenContext` so
        // later requests replay them — the AI keeps the resume/JD in
        // scope for the whole session, not just the first exchange.
        let attachmentBlocks: String? = hasAttachments
            ? attachments
                .map { "[Attached \($0.name)]\n\n\($0.extractedText)" }
                .joined(separator: "\n\n")
            : nil
        let prompt: String = {
            guard let blocks = attachmentBlocks else { return userText }
            return userText.isEmpty ? blocks : "\(blocks)\n\n\(userText)"
        }()

        // Sending a message implies the user wants to see the response —
        // but don't yank the Interview surface over to Chat mid-session;
        // both render the live conversation, and the flip re-laid-out the
        // focus card on every auto-send.
        if primarySurface != .interview {
            primarySurface = .chat
        }
        if shellStage != .expanded {
            withAnimation(Design.Motion.spring) {
                shellStage = .expanded
            }
        }

        let wasFirstExchange = sessionStore.activeSession.turns.isEmpty
        sessionStore.appendUser(userText,
                                attachments: attachments.map(\.name),
                                hiddenContext: attachmentBlocks)
        let assistantID = sessionStore.beginStreamingAssistant(model: selectedModel)

        if !showManualInput { transcription = "" }

        let snapshot = pendingScreenshot
        pendingQuickAction = nil
        if showManualInput { manualInput = "" }
        pendingScreenshot = nil
        pendingAttachments = []

        ai.runStream(userText: prompt,
                     screenshot: snapshot,
                     systemPrompt: resolvedPrompt,
                     history: historySnapshot,
                     assistantTurnID: assistantID,
                     wasFirstExchange: wasFirstExchange)
    }

    /// Manually push the current live transcription to the AI — used by the
    /// live-interview "send now" button so the user doesn't have to wait for
    /// a silence boundary or the auto-generate toggle. If the user has typed
    /// a draft in the bar, that takes priority; otherwise the accumulated
    /// transcription is sent. The mic keeps running and the transcript is
    /// cleared so the next utterance starts fresh.
    func sendTranscriptManually() {
        guard !isSendingToAI else { return }
        let typed = manualInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            showManualInput = true          // sendToAI sends + clears manualInput
            sendToAI()
            return
        }
        guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        showManualInput = false             // sendToAI sends + clears transcription
        // Apple keeps accumulating within a recognition task — without a
        // segment reset the text just sent resurfaces on the next update
        // and gets sent again. ElevenLabs needs no reset (clearing
        // `transcription` drops the committed backlog via didSet).
        if appleTranscriber.isRunning { appleTranscriber.resetSegment() }
        sendToAI()
    }

    /// Auto-send the live transcript during an interview and prep the
    /// transcriber for the next utterance. ElevenLabs keeps the WebSocket
    /// and capture running — its server-side VAD already segments
    /// utterances. Apple accumulates recognition text within a task, so
    /// it rolls to a fresh recognition segment in place
    /// (`resetSegment`) — the engine and taps keep running, so there's
    /// no deaf window between question and answer.
    private func autoSendLiveTranscript() async {
        // Echo suppression: if the segment is mostly words from the answer
        // we just showed, the mic is hearing the USER read the reply aloud
        // — not the interviewer asking something new. Sending it would
        // answer our own answer, over and over. Drop it and keep listening.
        let lastAnswer = sessionStore.activeSession.turns
            .last(where: { $0.role == .assistant })?.content ?? ""
        if TranscriptFilter.echoesAnswer(transcription, answer: lastAnswer) {
            NSLog("[AutoSend] dropped segment — reads as echo of the last answer")
            transcription = ""
            return
        }

        // Never hijack a typed draft — force the transcript path through
        // sendToAI, then restore the draft flag.
        let hadDraft = showManualInput && !manualInput.isEmpty
        showManualInput = false

        // Apple: roll to a fresh recognition segment in place so the
        // already-sent text can't resurface on the next update. The mic
        // and engine keep running throughout.
        if appleTranscriber.isRunning { appleTranscriber.resetSegment() }
        sendToAI()                     // captures + clears transcription
        if hadDraft { showManualInput = true }
    }

    /// Debounced auto-send for interview mode. A VAD commit doesn't
    /// necessarily mean the question is over — interviewers pause
    /// mid-sentence to think. Wait a grace window before sending: short
    /// when the transcript reads like a finished thought (terminal
    /// punctuation), long when it trails off mid-sentence. Any new speech
    /// cancels the pending send (see the onPartial/onUpdate handlers);
    /// the next commit reschedules with the fuller transcript, so a split
    /// question is sent whole instead of answered in halves.
    private func scheduleAutoSend() {
        pendingAutoSendTask?.cancel()
        // Near-constant grace: a "?" is a definitive end → go now; other
        // terminal punctuation → quick; unpunctuated/trailing-off → one
        // beat longer. The old 1400ms incomplete window made the SAME
        // question answer fast or slow depending on whether the engine
        // happened to punctuate it — the inconsistency users felt most.
        // Cancellation-on-new-speech (onPartial/onUpdate) remains the real
        // guard against answering mid-question.
        let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let grace: Duration
        if trimmed.hasSuffix("?") {
            grace = .milliseconds(120)
        } else if TranscriptFilter.seemsComplete(trimmed) {
            grace = .milliseconds(250)
        } else {
            grace = .milliseconds(900)
        }
        pendingAutoSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled else { return }
            guard self.isInterviewSession, self.interviewAutoGenerate,
                  !self.isInterviewPaused, self.isRecording,
                  !self.isSendingToAI else { return }
            guard TranscriptFilter.isMeaningful(self.transcription) else { return }
            // Detach before sending — sendToAI cancels pendingAutoSendTask
            // (to supersede stale sends), and that must not self-cancel
            // this task mid-flight.
            self.pendingAutoSendTask = nil
            await self.autoSendLiveTranscript()
        }
    }

    /// Called by AIController when a stream finishes. If the interviewer
    /// kept talking while the AI was answering, the committed transcript
    /// is waiting here — the silence boundary that should have sent it
    /// already fired and was consumed while `isSendingToAI` was true, so
    /// without this flush the queued question would sit unsent until the
    /// speaker happened to talk again.
    func flushPendingLiveTranscript() {
        guard isInterviewSession, interviewAutoGenerate, !isInterviewPaused,
              isRecording, !isSendingToAI else { return }
        let pending = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty, TranscriptFilter.isMeaningful(pending) else { return }
        // Goes through the same debounce as live commits — if the speaker
        // is mid-sentence right now, the next partial cancels it and the
        // next commit re-schedules with the full question.
        scheduleAutoSend()
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
                let speechGranted = await quickRecorder.requestPermission()
                if !speechGranted {
                    NSLog("[QuickAsk] speech recognition permission denied")
                    statusMessage    = ""
                    quickAskResponse = "Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
                    isQuickAsking    = false
                    return
                }
                let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
                if !micGranted {
                    NSLog("[QuickAsk] microphone permission denied")
                    statusMessage    = ""
                    quickAskResponse = "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."
                    isQuickAsking    = false
                    return
                }
                do {
                    try quickRecorder.start()
                } catch {
                    NSLog("[QuickAsk] quickRecorder.start failed: %@", error.localizedDescription)
                    statusMessage    = ""
                    quickAskResponse = "Error: \(error.localizedDescription)"
                    isQuickAsking    = false
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

        let resolvedPrompt = resolveActivePrompt()

        // Quick asks live in their own session (kind = .quickAsk) so they
        // don't bleed into whatever chat/interview the user is in the
        // middle of. We write turns by ID into the new session and leave
        // `activeSessionID` untouched so the current surface stays put.
        let quickSessionID = sessionStore.createQuickAskSession(
            workspaceID: workspaceStore.activeWorkspaceID
        )
        sessionStore.appendUser(to: quickSessionID, text)
        let assistantID = sessionStore.beginStreamingAssistant(
            in: quickSessionID, model: selectedModel
        )

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
                    history:      []
                )
                for try await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        accumulated += chunk
                        // Batched at ~30Hz — same rationale as AIController.
                        let now = ContinuousClock.now
                        if now - lastFlush >= .milliseconds(33) {
                            self.sessionStore.setStreamingContent(accumulated,
                                                                  turnID: assistantID,
                                                                  in: quickSessionID)
                            self.quickAskResponse = accumulated
                            lastFlush = now
                        }
                    case .usage(let inTok, let outTok):
                        self.sessionStore.finalizeAssistant(
                            turnID: assistantID,
                            in: quickSessionID,
                            inputTokens: inTok,
                            outputTokens: outTok
                        )
                    }
                }
                self.sessionStore.setStreamingContent(accumulated,
                                                      turnID: assistantID,
                                                      in: quickSessionID)
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

    func continueSession(id: UUID, stayInPrimarySurface: Bool = false) {
        sessionStore.continueSession(id: id)
        // Restore the mode for the reopened session so the right prompt kicks in.
        if let s = sessionStore.sessions.first(where: { $0.id == id }) {
            sessionMode = s.mode
            promptStore.activePresetID = s.promptPresetID
        }
        // Default: jump back to the chat surface so the reopened session is
        // visible. When the caller is already managing the surface (e.g.
        // resuming inside the Interview surface), leave primarySurface alone.
        if !stayInPrimarySurface {
            primarySurface = .chat
        }
    }

    func startNewSession(kind: ChatSession.Kind = .normal,
                         stayInPrimarySurface: Bool = false) {
        // Before closing the current session, ask the AI to give it a nicer title.
        let closingID = sessionStore.activeSessionID
        let closing = sessionStore.activeSession
        sessionStore.startNewSession(mode: sessionMode,
                                     promptPresetID: promptStore.activePresetID,
                                     workspaceID: workspaceStore.activeWorkspaceID,
                                     kind: kind)
        regenerateTitle(for: closing, sessionID: closingID)
        if !stayInPrimarySurface {
            primarySurface = .chat
        }
    }

    /// True when the Interview surface should render the live chat view
    /// instead of the setup form. Centralizing this here keeps the
    /// header title (TopStripView) and the surface body in lockstep so
    /// they never disagree about whether the user is in setup or in a
    /// session.
    var interviewSurfaceShowsChat: Bool {
        if isInterviewSession { return true }
        if forceInterviewSetup { return false }
        // Show the chat only when the user is parked on a session whose
        // kind matches the active mode tab (resumed from History or the
        // setup form's session picker). Never show some *other* session's
        // transcript just because one exists — that read as the app
        // resuming things on its own.
        let active = sessionStore.activeSession
        switch interviewSurfaceMode {
        case .interview:   return active.kind == .interview
        // Treat legacy .normal sessions as regular calls so old data
        // resumes on the Regular call tab rather than dumping the
        // user back into setup.
        case .regularCall: return active.kind == .regularCall || active.kind == .normal
        }
    }

    /// Called when the user clicks the Interview surface icon in the bar.
    /// When a live session is running it returns to it; otherwise it lands
    /// on the setup form — starting fresh is the dominant intent for this
    /// button, and silently dropping the user into an old session's
    /// transcript read as "the app resumed something I didn't ask for".
    /// Resuming stays one tap away: the setup form's session picker, or
    /// History → Continue.
    func openInterviewSurface() {
        if !isInterviewSession {
            forceInterviewSetup = true
        }
        primarySurface = .interview
    }

    /// Mark the active session as a paused live session. The bar will
    /// render the live controls (text input, model picker, pause/play,
    /// stop) but no transcriber starts until the user explicitly hits
    /// play — same shape as pausing a running interview, just without
    /// the prior recording.
    func enterPausedLiveState() {
        isInterviewSession  = true
        isInterviewPaused   = true
        isInterviewTextOnly = false
        // Re-entering live mode after a stop / from history — restart
        // the elapsed counter so the timer begins at 00:00 when the
        // user hits play, but stays at 00:00 while paused.
        interviewElapsedSeconds = 0
        interviewRunningSince   = nil
        endCapture(status: "Paused")
    }

    /// Switch the mode tab on the Interview surface. Just swaps which
    /// setup form is showing — switching tabs never silently jumps into
    /// an old session; resuming is always an explicit action (session
    /// picker or History).
    func switchInterviewSurfaceMode(_ mode: InterviewSurfaceMode) {
        guard mode != interviewSurfaceMode else { return }
        interviewSurfaceMode = mode
    }

    /// "+ new session" handler when the user is on the Interview surface.
    /// Tears down any paused-live state so the setup form actually
    /// renders (otherwise `interviewSurfaceShowsChat` keeps returning
    /// true). Doesn't create a session yet — the real session is created
    /// when the user hits Start in the form.
    func requestNewInterviewSession() {
        if isInterviewSession { stopInterviewSession() }
        forceInterviewSetup = true
    }

    /// Kick off a Regular call from the setup form. Mirrors
    /// `beginInterviewFromSetup` but skips the resume/JD plumbing — Regular
    /// call only carries system prompt + free-text context. If
    /// `regularCallAsCall` is true, also fires up the live transcriber so
    /// the user can talk through the panel; otherwise the session enters
    /// a text-only live state — the bar shows a text input + send button
    /// and the mic never starts.
    func beginRegularCallFromSetup() {
        sessionMode = regularCallAsCall ? .call : .general
        forceInterviewSetup = false

        startNewSession(kind: .regularCall, stayInPrimarySurface: true)

        // Same attachment treatment as the interview setup — see
        // beginInterviewFromSetup for why this doesn't go through
        // manualInput.
        let trimmedContext = interviewContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            pendingAttachments.append(
                PendingAttachment(name: "Call context", extractedText: trimmedContext)
            )
        }
        for ctx in interviewContextFiles where !ctx.extractedText.isEmpty {
            pendingAttachments.append(
                PendingAttachment(name: ctx.name, extractedText: ctx.extractedText)
            )
        }
        interviewContextFiles = []

        if regularCallAsCall {
            startInterviewSession()
        } else {
            // Text-only chat: keep `isInterviewSession` true so the bar
            // renders the text input + send + stop set, but no mic.
            isInterviewSession  = true
            isInterviewPaused   = true
            isInterviewTextOnly = true
            statusMessage       = ""
        }
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
        let hasContent = hasText || pendingScreenshot != nil || !pendingAttachments.isEmpty
        return hasContent && !isSendingToAI && hasKey
    }

    var needsKeyForCurrentModel: Bool {
        AIManager.shared.isOpenAIModel(selectedModel) ? openAIApiKey.isEmpty : apiKey.isEmpty
    }
}
