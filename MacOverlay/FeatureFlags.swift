import Foundation

/// Build-time feature visibility flags.
///
/// v1 ships with a deliberately narrow surface area: interview chat,
/// prompts, and account/settings. Everything else stays in the codebase
/// but is hidden from the UI — flip the relevant flag in a future version
/// to bring the feature back without re-implementing it.
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

    // MARK: - Hidden in v1, planned for a later release

    /// Embedded WebKit browser tabs inside the overlay. Heavy + maintenance
    /// burden, and its system-audio path needs the BlackHole driver +
    /// output-device reconfiguration — the most error-prone surface in the
    /// app. Users have a real browser. Plan: re-enable in v2.
    static let browserEnabled = false

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
    static let resumesEnabled = false

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
