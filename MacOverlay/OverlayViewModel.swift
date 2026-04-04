import AppKit
import Combine
import EventKit

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
    @Published var audioSource:    AudioSource = .microphone
    @Published var isRecording     = false
    @Published var transcription   = ""
    @Published var manualInput     = ""
    @Published var showManualInput = false
    @Published var statusMessage   = ""

    // MARK: - AI
    @Published var aiResponse     = ""
    @Published var isSendingToAI  = false
    @Published var pendingQuickAction: QuickAction? = nil
    @Published var pendingScreenshot: NSImage? = nil

    // MARK: - Notes
    @Published var sessionNotes:  [NoteEntry] = []
    @Published var showNotesPanel = false

    // MARK: - Embedded browser
    @Published var webURL: URL? = nil

    // MARK: - Calendar
    @Published var showCalendarPanel = false
    @Published var calendarEvents:   [EKEvent] = []
    @Published var calendarAuthorized = false
    let calendarManager = CalendarManager()

    // MARK: - Settings
    @Published var selectedModel:      String
    @Published var apiKey:             String
    @Published var openAIApiKey:       String
    @Published var opacity:            Double
    @Published var backgroundOpacity:  Double

    private let transcriptionManager = TranscriptionManager()
    private let notesManager         = NotesManager.shared
    private let reminderManager      = ReminderManager.shared
    private var cancellables         = Set<AnyCancellable>()
    private var calendarRefreshTimer: AnyCancellable?

    init() {
        apiKey           = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        openAIApiKey     = UserDefaults.standard.string(forKey: "openAIApiKey") ?? ""
        selectedModel    = UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-sonnet-4-6"
        opacity          = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 1.0
        backgroundOpacity = UserDefaults.standard.object(forKey: "backgroundOpacity") as? Double ?? 1.0
        userProfile      = UserProfileManager.shared.load()

        if let raw = UserDefaults.standard.string(forKey: "sessionMode"),
           let mode = SessionMode(rawValue: raw) {
            sessionMode = mode
        }

        // Persist settings
        $apiKey.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "anthropicAPIKey") }.store(in: &cancellables)
        $openAIApiKey.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "openAIApiKey") }.store(in: &cancellables)
        $selectedModel.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "selectedModel") }.store(in: &cancellables)
        $opacity.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "overlayOpacity") }.store(in: &cancellables)
        $backgroundOpacity.dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "backgroundOpacity") }.store(in: &cancellables)
        $sessionMode.dropFirst()
            .sink { UserDefaults.standard.set($0.rawValue, forKey: "sessionMode") }.store(in: &cancellables)
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

        transcriptionManager.onUpdate = { [weak self] text in
            Task { @MainActor [weak self] in self?.transcription = text }
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

    // MARK: - Quick actions

    func selectQuickAction(_ action: QuickAction) {
        pendingQuickAction = action
        if !transcription.isEmpty || !manualInput.isEmpty { sendToAI() }
    }

    // MARK: - AI

    func sendToAI() {
        let baseText   = showManualInput && !manualInput.isEmpty ? manualInput : transcription
        let prefix     = pendingQuickAction.map { $0.promptPrefix } ?? ""
        let textToSend = prefix + baseText

        guard !textToSend.isEmpty || pendingScreenshot != nil else { return }

        let isOpenAI = AIManager.shared.isOpenAIModel(selectedModel)
        if  isOpenAI && openAIApiKey.isEmpty { return }
        if !isOpenAI && apiKey.isEmpty       { return }

        // Personalise system prompt
        let resolvedPrompt = sessionMode.systemPrompt
            .replacingOccurrences(of: "{NAME}",    with: userProfile.name.isEmpty        ? "the user"      : userProfile.name)
            .replacingOccurrences(of: "{ROLE}",    with: userProfile.currentRole.isEmpty ? "a professional": userProfile.currentRole)
            .replacingOccurrences(of: "{COMPANY}", with: userProfile.company.isEmpty     ? "their company" : userProfile.company)

        isSendingToAI     = true
        aiResponse        = ""
        let snapshot      = pendingScreenshot
        pendingQuickAction = nil

        Task {
            do {
                aiResponse = try await AIManager.shared.sendMessage(
                    textToSend,
                    apiKey:       apiKey,
                    openAIApiKey: openAIApiKey,
                    model:        selectedModel,
                    screenshot:   snapshot,
                    systemPrompt: resolvedPrompt
                )
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
