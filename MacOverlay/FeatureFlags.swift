import Foundation

/// Build-time feature visibility flags.
///
/// Production ships only the interview helper: interview setup (résumé,
/// context, system prompt, model) and the live interview surface.
/// Everything else stays in the codebase but is hidden from the UI — flip
/// the relevant flag in a future version to bring the feature back without
/// re-implementing it.
///
/// Flags set to `previewFeatures` are on in Dev and Beta builds and off in
/// Production. That's how a feature gets tested with beta users before it
/// graduates: when it's ready, change its flag to `true`.
///
/// Why hide instead of delete:
/// - Less rework when bringing a feature back in v2/v3.
/// - The underlying code (managers, stores, panels) keeps compiling and
///   keeps getting tested by the rest of the app's plumbing.
/// - Diff against `main` stays small and reviewable.
///
/// Why hide instead of leave-on:
/// - Smaller surface to test, document, and write support replies for.
/// - Fewer permission prompts at first launch.
/// - Faster onboarding — users see only what we want them focused on.
enum FeatureFlags {

    /// True in Dev and Beta builds, false in Production.
    static let previewFeatures = AppChannel.current.showsPreviewFeatures

    // MARK: - Beta only, candidates for production

    /// "Regular call" setup next to "Interview" on the Interview surface,
    /// plus its History tab.
    static let regularCallEnabled = previewFeatures

    /// Subscribing to TheCloser Pro from the app. Dev and Beta only while
    /// the Stripe prices are the $1 test prices; production shows the plans
    /// as coming soon.
    static let proSubscriptionsEnabled = previewFeatures

    // MARK: - Off in every build while v1 focuses on the interview helper

    /// Quick Ask: hold Fn/🌐 (or ⌃⌥Q) to ask by voice, plus its Preferences
    /// tab and History tab.
    static let quickAskEnabled = false

    /// Hold ⌥ to dictate into the frontmost app. Off also means the app
    /// never asks for Accessibility permission.
    static let dictationEnabled = false

    /// ⌃⌥C explain clipboard and ⌃⌥A send selection to the AI.
    static let clipboardShortcutsEnabled = false

    // MARK: - Hidden in v1, planned for a later release

    /// Peer Control Server — let a colleague view your overlay and send
    /// messages to the AI over LAN. Cool tech demo, near-zero real-world
    /// demand right now. Plan: re-enable in v2.
    static let peerControlEnabled = false

    /// Résumé tailoring surface — import a résumé, paste a JD, and generate
    /// a tailored DOCX with before/after scoring. Hidden for the first
    /// public release so v1 stays focused on the live-interview copilot;
    /// the generation pipeline (ResumeController, ResumeStore, DOCX
    /// text_editor loop) still compiles and is exercised by the rest of the
    /// app. Flip back on once the editor/output flow is polished. Re-enabling
    /// this only restores UI entry points — no re-implementation needed.
    /// The interview setup has its own résumé picker, so an interview can
    /// still use a résumé with this off. Off in every build, scoring
    /// hotkeys included.
    static let resumesEnabled = false

    /// Embedded WebKit browser tabs inside the overlay — a Browser bar
    /// surface plus the Tools-menu toggle, both feeding the same
    /// `BrowserPanelView` (tabs, split view, per-tab WKWebView). Plain
    /// browsing only; like every panel it's hidden from screen sharing.
    static let browserEnabled = true

    // MARK: - Hidden in v1, no current plans to bring back

    /// Calendar + Reminders integration via EventKit. The interview-helper
    /// product story doesn't need calendar reminders; if we re-add it later
    /// it'll be opt-in per workspace.
    static let calendarEnabled = false

    /// Multiple workspaces with per-workspace feature toggles. Overkill for
    /// v1 — every user gets one implicit workspace. The underlying
    /// WorkspaceStore + default workspace stays so sessions still group
    /// correctly under the hood.
    static let workspacesEnabled = false

    /// Sessions / chat history sidebar entry. Re-enabled in the redesigned
    /// UI — there's now a dedicated History button next to the New Session
    /// "+" in the composer that brings up the headed surface for browsing
    /// past sessions. The underlying flag still exists so we can take it
    /// back out cleanly if needed.
    static let sessionsHistoryEnabled = true
}
