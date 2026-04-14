import AppKit
import Combine
import EventKit

struct BrowserTab: Identifiable {
    let id  = UUID()
    var url: URL
    var title: String = ""
}

struct ResumeScore {
    let score:     Int
    let verdict:   String
    let missing:   [String]
    let strengths: [String]

    // Parses the strict format the AI is asked to return
    init(raw: String) {
        var s = 0; var v = ""; var m: [String] = []; var st: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SCORE:") {
                s = Int(l.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if l.hasPrefix("VERDICT:") {
                v = String(l.dropFirst(8).trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("MISSING_KEYWORDS:") {
                m = l.dropFirst(17).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if l.hasPrefix("STRENGTHS:") {
                st = l.dropFirst(10).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        score = s; verdict = v; missing = m; strengths = st
    }

    init(score: Int, verdict: String, missing: [String], strengths: [String]) {
        self.score = score; self.verdict = verdict
        self.missing = missing; self.strengths = strengths
    }

    var color: String {
        score >= 80 ? "green" : score >= 60 ? "yellow" : "red"
    }
    var recommendation: String {
        score >= 80 ? "Good match — safe to apply as-is"
                    : score >= 60 ? "Decent match — minor tweaks recommended"
                    : "Low match — use Ctrl+Opt+R to tailor your resume"
    }
}

@MainActor
class OverlayViewModel: ObservableObject {

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
    @Published var sessionMode: SessionMode = .general
    @Published var userProfile: UserProfile

    // MARK: - Audio / transcription
    @Published var audioSource:       AudioSource = .microphone
    @Published var isRecording        = false
    @Published var vadEnabled:        Bool
    @Published var isInterviewSession = false  // continuous real-time interview mode
    @Published var transcription   = ""
    @Published var manualInput     = ""
    @Published var showManualInput = false
    @Published var statusMessage   = ""

    // MARK: - AI
    @Published var aiResponse     = ""
    @Published var isSendingToAI  = false
    @Published var pendingQuickAction: QuickAction? = nil
    @Published var pendingScreenshot: NSImage? = nil

    // MARK: - Quick ask (Ctrl+Opt+Q)
    @Published var isQuickAsking     = false
    @Published var quickAskResponse  = ""
    @Published var isQuickAskSending = false

    // MARK: - Option-key dictation
    @Published var isDictating    = false
    @Published var dictationText  = ""

    // MARK: - Notes
    @Published var sessionNotes:  [NoteEntry] = []
    @Published var showNotesPanel = false

    // MARK: - Resume builder
    @Published var showResumeBuilder  = false
    @Published var resumeJD           = ""
    @Published var resumeBase:        String   // saved once, reused for all JDs
    @Published var resumeOutput       = ""
    @Published var resumeFileURL:     URL? = nil
    @Published var isGeneratingResume = false

    // MARK: - Resume score
    @Published var resumeScore:        ResumeScore? = nil
    @Published var isScoringResume     = false

    // MARK: - Embedded browser
    @Published var browserTabs: [BrowserTab] = []
    @Published var activeTabID: UUID? = nil
    @Published var splitCount: Int = 1

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
    }

    func toggleBrowser() {
        if hasBrowser { browserTabs = []; activeTabID = nil; splitCount = 1 }
        else { addTab() }
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
    @Published var showCalendarPanel = false
    @Published var calendarEvents:   [EKEvent] = []
    @Published var calendarAuthorized = false
    let calendarManager = CalendarManager()

    // MARK: - Settings
    @Published var selectedModel:      String
    @Published var apiKey:             String
    @Published var openAIApiKey:       String
    @Published var elevenLabsAPIKey:      String
    @Published var opacity:            Double
    @Published var backgroundOpacity:  Double
    @Published var customSystemPrompt: String   // overrides mode default when non-empty

    // Last 3 Q&A turns sent as context on every new message
    private var conversationHistory: [(user: String, assistant: String)] = []
    private let maxHistoryTurns = 3

    // MARK: - Peer control
    let peerServer = PeerControlServer.shared
    @Published var peerControlEnabled: Bool
    /// Staging area for messages the peer wants to send — shown to the local user
    /// for review before going to AI.  Empty = nothing pending.
    @Published var peerMessage: String = ""

    let transcriptionManager = TranscriptionManager()
    private let quickRecorder        = QuickRecorder.shared
    private let notesManager         = NotesManager.shared
    private let reminderManager      = ReminderManager.shared
    private var cancellables         = Set<AnyCancellable>()
    private var calendarRefreshTimer: AnyCancellable?

    init() {
        vadEnabled          = UserDefaults.standard.bool(forKey: "vadEnabled")
        customSystemPrompt  = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        resumeBase          = UserDefaults.standard.string(forKey: "resumeBase") ?? ""
        apiKey              = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        openAIApiKey        = UserDefaults.standard.string(forKey: "openAIApiKey") ?? ""
        elevenLabsAPIKey       = UserDefaults.standard.string(forKey: "elevenLabsAPIKey") ?? ""
        selectedModel    = UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-sonnet-4-6"
        opacity          = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 1.0
        backgroundOpacity = UserDefaults.standard.object(forKey: "backgroundOpacity") as? Double ?? 1.0
        userProfile      = UserProfileManager.shared.load()
        peerControlEnabled = UserDefaults.standard.bool(forKey: "peerControlEnabled")

        if let raw = UserDefaults.standard.string(forKey: "sessionMode"),
           let mode = SessionMode(rawValue: raw) {
            sessionMode = mode
        }

        // Persist settings
        $apiKey.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "anthropicAPIKey") }.store(in: &cancellables)
        $openAIApiKey.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "openAIApiKey") }.store(in: &cancellables)
        $elevenLabsAPIKey.dropFirst()
            .sink { [weak self] key in
                UserDefaults.standard.set(key, forKey: "elevenLabsAPIKey")
                self?.transcriptionManager.elevenLabsAPIKey = key
            }.store(in: &cancellables)
        $selectedModel.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "selectedModel") }.store(in: &cancellables)
        $opacity.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "overlayOpacity") }.store(in: &cancellables)
        $backgroundOpacity.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "backgroundOpacity") }.store(in: &cancellables)
        $sessionMode.dropFirst()
            .sink { [weak self] mode in
                UserDefaults.standard.set(mode.rawValue, forKey: "sessionMode")
                self?.conversationHistory = []   // fresh context for new mode
            }.store(in: &cancellables)
        $userProfile.dropFirst()
            .sink { UserProfileManager.shared.save($0) }.store(in: &cancellables)

        // Sync calendar events from manager
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

        $vadEnabled.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "vadEnabled") }.store(in: &cancellables)
        $customSystemPrompt.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "customSystemPrompt") }.store(in: &cancellables)
        $resumeBase.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "resumeBase") }.store(in: &cancellables)

        // Peer control — persist enabled state; broadcast overlay state to connected peers
        $peerControlEnabled.dropFirst()
            .sink { [weak self] enabled in
                UserDefaults.standard.set(enabled, forKey: "peerControlEnabled")
                if enabled { self?.peerServer.start() } else { self?.peerServer.stop() }
            }.store(in: &cancellables)

        // Broadcast whenever visible state changes (throttle to avoid flooding SSE)
        let broadcastPub = Publishers.MergeMany([
            $transcription.map { _ in () }.eraseToAnyPublisher(),
            $aiResponse.map { _ in () }.eraseToAnyPublisher(),
            $isSendingToAI.map { _ in () }.eraseToAnyPublisher(),
            $isRecording.map { _ in () }.eraseToAnyPublisher(),
            $sessionMode.map { _ in () }.eraseToAnyPublisher(),
            $statusMessage.map { _ in () }.eraseToAnyPublisher(),
            $browserTabs.map { _ in () }.eraseToAnyPublisher(),
            $activeTabID.map { _ in () }.eraseToAnyPublisher(),
            $peerMessage.map { _ in () }.eraseToAnyPublisher()
        ])
        broadcastPub
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.peerServer.broadcastState() }
            .store(in: &cancellables)

        // Connect peer server to self and start if previously enabled
        peerServer.viewModel = self
        if peerControlEnabled { peerServer.start() }

        transcriptionManager.elevenLabsAPIKey = elevenLabsAPIKey

        transcriptionManager.onUpdate = { [weak self] text in
            Task { @MainActor [weak self] in self?.transcription = text }
        }

        transcriptionManager.onSilence = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.transcription.isEmpty else { return }

                // Quick ask is handled by QuickRecorder (SFSpeechRecognizer) — ignore here
                if self.isQuickAsking { return }

                guard self.isRecording else { return }

                if self.isInterviewSession {
                    // Continuous mode: stop engine, send segment, clear, restart
                    guard !self.isSendingToAI else { return }
                    self.transcriptionManager.stop()
                    self.isRecording = false
                    self.statusMessage = ""

                    self.sendToAI()          // captures transcription before we clear
                    self.transcription = ""

                    // Restart after a short pause (lets mic settle)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard self.isInterviewSession else { return }
                    do {
                        try await self.transcriptionManager.start(source: self.audioSource)
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
            transcriptionManager.stop()
            isRecording   = false
            statusMessage = ""
        } else {
            transcription = ""
            aiResponse    = ""
            statusMessage = "Starting..."
            Task {
                do {
                    try await transcriptionManager.start(source: audioSource)
                    isRecording   = true
                    statusMessage = "Recording"
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
            transcriptionManager.stop()
            isRecording   = false
            statusMessage = ""
            if !transcription.isEmpty { sendToAI() }
        } else {
            transcription = ""
            aiResponse    = ""
            statusMessage = "Starting..."
            Task {
                do {
                    try await transcriptionManager.start(source: audioSource)
                    isRecording   = true
                    statusMessage = "Recording"
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
        statusMessage = "Starting..."
        Task {
            do {
                try await transcriptionManager.start(source: audioSource)
                isRecording   = true
                statusMessage = "Recording"
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
            transcriptionManager.stop()
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

        // System prompt: custom override takes priority over mode default
        let resolvedPrompt: String
        if !customSystemPrompt.isEmpty {
            resolvedPrompt = customSystemPrompt
        } else {
            resolvedPrompt = sessionMode.systemPrompt
                .replacingOccurrences(of: "{NAME}",    with: userProfile.name.isEmpty        ? "the user"       : userProfile.name)
                .replacingOccurrences(of: "{ROLE}",    with: userProfile.currentRole.isEmpty ? "a professional" : userProfile.currentRole)
                .replacingOccurrences(of: "{COMPANY}", with: userProfile.company.isEmpty     ? "their company"  : userProfile.company)
        }

        isSendingToAI     = true
        aiResponse        = ""
        let snapshot      = pendingScreenshot
        pendingQuickAction = nil
        let historySnapshot = conversationHistory

        Task {
            do {
                let response = try await AIManager.shared.sendMessage(
                    textToSend,
                    apiKey:       apiKey,
                    openAIApiKey: openAIApiKey,
                    model:        selectedModel,
                    screenshot:   snapshot,
                    systemPrompt: resolvedPrompt,
                    history:      historySnapshot
                )
                aiResponse = response

                // Save turn to history (cap at maxHistoryTurns)
                conversationHistory.append((user: textToSend, assistant: response))
                if conversationHistory.count > maxHistoryTurns {
                    conversationHistory.removeFirst()
                }

                // Auto-save AI response to notes
                notesManager.add(content: aiResponse, source: .ai, mode: sessionMode)
                sessionNotes = notesManager.entries
            } catch {
                aiResponse = "Error: \(error.localizedDescription)"
            }
            isSendingToAI     = false
            pendingScreenshot = nil
            if showManualInput { manualInput = "" }
        }
    }

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

        let resolvedPrompt = customSystemPrompt.isEmpty
            ? sessionMode.systemPrompt
                .replacingOccurrences(of: "{NAME}",    with: userProfile.name.isEmpty        ? "the user"       : userProfile.name)
                .replacingOccurrences(of: "{ROLE}",    with: userProfile.currentRole.isEmpty ? "a professional" : userProfile.currentRole)
                .replacingOccurrences(of: "{COMPANY}", with: userProfile.company.isEmpty     ? "their company"  : userProfile.company)
            : customSystemPrompt
        let historySnapshot = conversationHistory

        Task {
            do {
                let result = try await AIManager.shared.sendMessage(
                    text,
                    apiKey:       apiKey,
                    openAIApiKey: openAIApiKey,
                    model:        selectedModel,
                    screenshot:   nil,
                    systemPrompt: resolvedPrompt,
                    history:      historySnapshot
                )
                quickAskResponse = result
                conversationHistory.append((user: text, assistant: result))
                if conversationHistory.count > maxHistoryTurns { conversationHistory.removeFirst() }
                notesManager.add(content: result, source: .ai, mode: sessionMode)
                sessionNotes = notesManager.entries
            } catch {
                quickAskResponse = "Error: \(error.localizedDescription)"
            }
            isQuickAskSending = false
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
        conversationHistory = []
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

    // Called by hotkey: reads clipboard as JD, uses saved resumeBase
    func generateResumeFromClipboard() {
        guard let jd = NSPasteboard.general.string(forType: .string), !jd.isEmpty else { return }
        resumeJD      = jd
        showResumeBuilder = true
        generateResume()
    }

    // Called by hotkey: scores current resume against clipboard JD
    func scoreResumeFromClipboard() {
        guard let jd = NSPasteboard.general.string(forType: .string), !jd.isEmpty else { return }
        guard !resumeBase.isEmpty, !apiKey.isEmpty else { return }
        resumeJD      = jd
        resumeScore   = nil
        isScoringResume = true
        showResumeBuilder = true

        let base = resumeBase
        let prompt = """
        Job Description:
        \(jd)

        Resume:
        \(base)

        Analyse how well this resume matches the job description. Respond with ONLY this exact format (no other text):
        SCORE: [0-100]
        VERDICT: [one short sentence — e.g. "Strong match, minimal tailoring needed" or "Significant gaps, customisation recommended"]
        MISSING_KEYWORDS: [comma-separated list of up to 6 important keywords from the JD not in the resume]
        STRENGTHS: [comma-separated list of up to 4 matching strengths]
        """

        Task {
            do {
                let raw = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey:       apiKey,
                    openAIApiKey: openAIApiKey,
                    model:        "claude-haiku-4-5-20251001",
                    screenshot:   nil,
                    systemPrompt: "You are an ATS and resume expert. Always respond in the exact format requested."
                )
                resumeScore = ResumeScore(raw: raw)
            } catch {
                resumeScore = ResumeScore(score: 0, verdict: "Error: \(error.localizedDescription)",
                                          missing: [], strengths: [])
            }
            isScoringResume = false
        }
    }

    func generateResume() {
        guard !resumeJD.isEmpty, !resumeBase.isEmpty, !apiKey.isEmpty else { return }
        isGeneratingResume = true
        resumeOutput       = ""
        resumeFileURL      = nil

        let jd   = resumeJD
        let base = resumeBase
        let prompt = """
        Job Description:
        \(jd)

        Current Resume:
        \(base)

        Write a tailored, ATS-optimised resume for this role. Rules:
        - Use only information from the provided resume — invent nothing.
        - Use keywords from the job description.
        - Section headings must be ALL CAPS on their own line (e.g. SUMMARY, EXPERIENCE, EDUCATION, SKILLS).
        - Bullet points must start with "- ".
        - No markdown, no asterisks, no symbols except dashes for bullets.
        - Output plain text only.
        """

        Task {
            do {
                let result = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey:       apiKey,
                    openAIApiKey: openAIApiKey,
                    model:        "claude-haiku-4-5-20251001",
                    screenshot:   nil,
                    systemPrompt: "You are an expert resume writer. Output clean plain text with ALL CAPS section headings and '- ' bullet points. No markdown."
                )
                resumeOutput = result
                resumeFileURL = try Self.saveResumeDOCX(text: result)
            } catch {
                resumeOutput = "Error: \(error.localizedDescription)"
            }
            isGeneratingResume = false
        }
    }

    // Builds a valid .docx (Office Open XML) from plain text.
    // DOCX = ZIP archive containing XML files — no third-party dependencies needed.
    private static func saveResumeDOCX(text: String) throws -> URL {
        let fm = FileManager.default
        let tempDir     = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wordDir     = tempDir.appendingPathComponent("word")
        let relsDir     = tempDir.appendingPathComponent("_rels")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        for dir in [tempDir, wordDir, relsDir, wordRelsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Convert plain-text lines to Word paragraph XML
        var parasXML = ""
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { parasXML += "<w:p/>\n"; continue }

            var content   = t
            var bold      = false
            var szVal     = "22"      // 11 pt (half-points)
            var indentXML = ""

            if content.hasPrefix("# ") {
                content = String(content.dropFirst(2)); bold = true; szVal = "32"
            } else if content.hasPrefix("## ") {
                content = String(content.dropFirst(3)); bold = true; szVal = "26"
            } else if content.hasPrefix("### ") {
                content = String(content.dropFirst(4)); bold = true; szVal = "24"
            } else if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("• ") {
                let body = content.drop(while: { !$0.isLetter && $0 != "(" })
                content  = "• \(body)"
                indentXML = "<w:pPr><w:ind w:left=\"360\" w:hanging=\"180\"/></w:pPr>"
            } else {
                // ALL-CAPS line → section heading
                let letters = content.filter { $0.isLetter }
                if letters.count > 2 && letters == letters.uppercased() {
                    bold = true; szVal = "24"
                }
            }

            let escaped = content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            let rpr = "<w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/>"
                    + (bold ? "<w:b/>" : "")
                    + "<w:sz w:val=\"\(szVal)\"/><w:szCs w:val=\"\(szVal)\"/></w:rPr>"

            parasXML += "<w:p>\(indentXML)<w:r>\(rpr)"
                      + "<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>\n"
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(parasXML)
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        let wordRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """

        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"),
                                atomically: true, encoding: .utf8)
        try rootRels.write(to: relsDir.appendingPathComponent(".rels"),
                           atomically: true, encoding: .utf8)
        try document.write(to: wordDir.appendingPathComponent("document.xml"),
                           atomically: true, encoding: .utf8)
        try wordRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"),
                           atomically: true, encoding: .utf8)

        // Package into a ZIP archive (DOCX is just a ZIP)
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("resume_\(Int(Date().timeIntervalSince1970)).docx")
        try? fm.removeItem(at: outputURL)

        let zip = Process()
        zip.executableURL     = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        // Pass filenames as separate arguments — no shell, so [] are safe
        zip.arguments = ["-r", outputURL.path,
                         "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()

        try? fm.removeItem(at: tempDir)

        guard fm.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "ResumeDOCX", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zip failed"])
        }
        return outputURL
    }

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
