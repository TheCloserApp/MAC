//! The egui overlay UI and all per-frame wiring.
//!
//! Recreates the macOS shell 1:1: a waveform brand pill that expands into a
//! composer showing three surface icons — Interview, Résumé, Profile. The
//! Interview surface has the Mac setup form (mode tabs, profile, context,
//! missing-key banner, Start capsule) and the live view: transcript strip
//! with a session timer, copy button and full-history drop-down; a Live
//! Focus Q&A card with ‹ › navigation, a stop button, hover-revealed
//! Copy / Retry / re-ask-with-model actions; and a full-conversation mode
//! with chat bubbles. Transient AI errors auto-retry once. Window is
//! borderless + translucent and (on Windows) excluded from screen capture.

mod interview;
mod profile;
mod resume;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use egui::text::LayoutJob;
use egui::{
    pos2, vec2, Align, Color32, FontId, Layout, Margin, Rect, Response, RichText, Rounding, Sense,
    Stroke, TextFormat, Vec2, ViewportCommand,
};

use copilot_core::ai::AiRequest;
use copilot_core::filter::TranscriptFilter;
use copilot_core::models::available_models;
use copilot_core::prompt::{self, Attachment};
use copilot_core::prompts::{PromptKind, PromptStore};
use copilot_core::resumes::{self, ResumeScore, ResumeStore};
use copilot_core::settings::{AudioSource, Settings};
use copilot_core::SessionMode;

use crate::backend::{Backend, UiEvent};
use crate::hotkeys::{HotkeyAction, Hotkeys};
use crate::theme;

/// The collapsed brand pill: just big enough for the waveform plus its card
/// padding. Keep this and `main.rs`'s `with_min_inner_size` in step — a
/// larger minimum silently clamps the pill back up.
const PILL_SIZE: Vec2 = Vec2::new(62.0, 42.0);
const BAR_HEIGHT: f32 = 68.0;
/// Non-content width of the composer bar: the card's inner margin (14 each
/// side) plus the panel's outer margin (6 each side).
const BAR_CHROME_W: f32 = 2.0 * (14.0 + 6.0);
/// Starting width of the idle launcher bar, before the row is measured.
const BAR_COMPACT_W: f32 = 430.0;
const MOVE_STEP: f32 = 40.0;
const RESIZE_STEP: f32 = 40.0;
const MIN_PANEL: Vec2 = Vec2::new(340.0, 260.0);
/// How long the "Copied ✓" feedback stays lit.
const COPY_FLASH: Duration = Duration::from_millis(1300);
/// Grace before a transient AI error is retried automatically.
const AUTO_RETRY_DELAY: Duration = Duration::from_millis(700);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Surface {
    Interview,
    Resume,
    Profile,
}

/// Where a streaming reply should land. Several kinds of request are in
/// flight at once (a live answer, a résumé rewrite, two scoring passes), so
/// each turn id carries its destination instead of using a field per case.
#[derive(Clone, Copy, PartialEq, Eq)]
enum AiTarget {
    /// A normal Q&A turn in the session.
    Turn,
    /// The tailored-résumé stream for this generation.
    Generation(u64),
    /// An ATS score for this generation — before or after tailoring.
    Score { generation: u64, after: bool },
}

/// Tabs of the Résumé surface (the Mac panel's Build / Generations).
#[derive(Clone, Copy, PartialEq, Eq)]
enum ResumeTab {
    Build,
    Generations,
}

/// Tabs of the Profile surface (the Mac Preferences window's rail).
#[derive(Clone, Copy, PartialEq, Eq)]
enum ProfileTab {
    Ai,
    Transcription,
    Profile,
    Panel,
    QuickAsk,
    Prompts,
    Shortcuts,
}

impl ProfileTab {
    const ALL: [ProfileTab; 7] = [
        ProfileTab::Ai,
        ProfileTab::Transcription,
        ProfileTab::Profile,
        ProfileTab::Panel,
        ProfileTab::QuickAsk,
        ProfileTab::Prompts,
        ProfileTab::Shortcuts,
    ];

    fn title(self) -> &'static str {
        match self {
            ProfileTab::Ai => "AI",
            ProfileTab::Transcription => "Transcription",
            ProfileTab::Profile => "Profile",
            ProfileTab::Panel => "Panel",
            ProfileTab::QuickAsk => "Quick Ask",
            ProfileTab::Prompts => "Prompts",
            ProfileTab::Shortcuts => "Shortcuts",
        }
    }
}

/// An open "new / edit system prompt" sheet.
struct PromptDraft {
    /// `None` while creating, `Some(id)` while editing an existing preset.
    editing: Option<u64>,
    name: String,
    content: String,
    kind: PromptKind,
}

#[derive(Clone, Copy)]
enum IconKind {
    Monitor,
    Document,
    Person,
}

struct Turn {
    id: u64,
    user: String,
    assistant: String,
    streaming: bool,
    input_tokens: u32,
    output_tokens: u32,
    error: bool,
    /// One free automatic retry per turn for transient failures
    /// (rate limits, overloads, dropped connections).
    auto_retried: bool,
}

pub struct App {
    settings: Settings,
    settings_path: PathBuf,
    backend: Backend,
    ui_rx: Receiver<UiEvent>,
    hotkeys: Option<Hotkeys>,
    overlay_applied: bool,

    collapsed: bool,
    surface: Option<Surface>,
    status: String,

    transcript: String,
    pending_since: Option<Instant>,
    recording_since: Option<Instant>,
    /// Accumulated session time across pauses, so the timer freezes on
    /// pause and resumes instead of restarting (the Mac LiveSessionTimer).
    session_elapsed: Duration,
    turns: Vec<Turn>,
    next_turn_id: u64,
    input: String,

    focus_mode: bool,
    show_transcript: bool,
    focus_offset: usize,
    /// Transcript-history drop-down (the Mac strip chevron).
    transcript_expanded: bool,

    /// "Copied ✓" flashes, keyed by widget id.
    copied: HashMap<egui::Id, Instant>,
    /// A transient AI failure waiting for its automatic retry.
    auto_retry: Option<(u64, Instant)>,
    /// Destination for each in-flight stream.
    ai_targets: HashMap<u64, AiTarget>,

    // ── Libraries ───────────────────────────────────────────────────────
    prompts: PromptStore,
    resumes: ResumeStore,
    /// Files attached to the interview session (JD, notes, briefing docs).
    attachments: Vec<Attachment>,
    /// Open "new / edit prompt" sheet, if any.
    prompt_draft: Option<PromptDraft>,

    // ── Résumé surface ──────────────────────────────────────────────────
    resume_tab: ResumeTab,
    /// Show the résumé library list instead of the active résumé's body.
    show_resume_library: bool,
    jd_text: String,
    /// Generation currently streaming, if any.
    active_generation: Option<u64>,
    /// Scoring pass in flight (generation id, is_after).
    scoring: Option<(u64, bool)>,
    /// Buffer for a scoring reply while it streams.
    score_buf: String,
    /// Generation opened in the history detail view.
    open_generation: Option<u64>,

    // ── Profile surface ─────────────────────────────────────────────────
    profile_tab: ProfileTab,

    quick_ask_started: bool,
    force_send_next: bool,

    last_saved_geo: (f32, f32, f32, f32),
    last_save: Instant,
    /// Measured width of the idle launcher row (see `BAR_CHROME_W`).
    launcher_w: f32,
    /// Hover-reveal state for the chrome (see `update_chrome_reveal`).
    chrome_alpha: f32,
    chrome_interactive: bool,

    /// UI-gallery mode (`THECLOSER_DEMO=<dir>`): steps through every surface
    /// with seeded data, saves a PNG per scene, then quits. Dev aid only.
    demo: Option<DemoState>,
}

struct DemoState {
    out: PathBuf,
    scene: usize,
    since: Instant,
    requested: bool,
    /// Stand in for "the cursor is over the window", which a headless
    /// capture run never has, so the gallery can show the revealed chrome.
    force_chrome: bool,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, settings: Settings, settings_path: PathBuf) -> Self {
        theme::install(&cc.egui_ctx, settings.font_scale);
        let (ui_tx, ui_rx) = std::sync::mpsc::channel::<UiEvent>();
        let backend = Backend::new(cc.egui_ctx.clone(), ui_tx);
        let (hotkeys, status) = match Hotkeys::new() {
            Ok(h) => (Some(h), String::new()),
            Err(e) => (None, format!("Global hotkeys unavailable: {e}")),
        };
        let mut resumes = ResumeStore::load();
        // First run with context already typed: seed the library from it so the
        // Build tab opens on something real instead of an empty editor.
        if resumes.presets.is_empty() && !settings.context.trim().is_empty() {
            resumes.add("My résumé", &settings.context, None);
        }
        let mut app = App {
            last_saved_geo: (settings.panel_x, settings.panel_y, settings.panel_width, settings.panel_height),
            settings,
            settings_path,
            backend,
            ui_rx,
            hotkeys,
            overlay_applied: false,
            collapsed: false,
            surface: None,
            status,
            transcript: String::new(),
            pending_since: None,
            recording_since: None,
            session_elapsed: Duration::ZERO,
            turns: Vec::new(),
            next_turn_id: 1,
            input: String::new(),
            focus_mode: true,
            show_transcript: true,
            focus_offset: 0,
            transcript_expanded: false,
            copied: HashMap::new(),
            auto_retry: None,
            ai_targets: HashMap::new(),
            prompts: PromptStore::load(),
            resumes,
            attachments: Vec::new(),
            prompt_draft: None,
            resume_tab: ResumeTab::Build,
            show_resume_library: false,
            jd_text: String::new(),
            active_generation: None,
            scoring: None,
            score_buf: String::new(),
            open_generation: None,
            profile_tab: ProfileTab::Ai,
            quick_ask_started: false,
            force_send_next: false,
            last_save: Instant::now(),
            launcher_w: BAR_COMPACT_W,
            chrome_alpha: 1.0,
            chrome_interactive: true,
            demo: None,
        };
        if let Some(dir) = std::env::var_os("THECLOSER_DEMO") {
            let out = PathBuf::from(dir);
            let _ = std::fs::create_dir_all(&out);
            // `main` already redirected the whole config directory here, so
            // every store in this run is scoped to the demo folder.
            //
            // Drop the global hotkeys too: they're registered system-wide, so
            // a stray Ctrl+Alt+Space from anywhere on the machine would
            // collapse the window mid-capture and silently corrupt the
            // gallery (it did — two scenes came out as the pill).
            app.hotkeys = None;
            app.demo_seed_profile();
            app.demo = Some(DemoState { out, scene: 0, since: Instant::now(), requested: false, force_chrome: false });
            app.demo_apply_scene(&cc.egui_ctx, 0);
        }
        app
    }

    // ── UI gallery (THECLOSER_DEMO) ─────────────────────────────────────────

    fn demo_seed_profile(&mut self) {
        self.settings.user_name = "Alex Carter".into();
        self.settings.user_role = "Senior Backend Engineer".into();
        self.settings.user_company = "Nimbus Cloud".into();
        self.settings.anthropic_key = "sk-demo".into();
        self.settings.context = "8 yrs backend (Rust, Go, Postgres). Led the checkout-service rewrite at Nimbus — 40% p99 latency cut. Interviewing for Staff Engineer, payments platform.".into();
        self.settings.session_mode = SessionMode::Interview;
    }

    fn demo_seed_session(&mut self) {
        self.turns = vec![
            Turn {
                id: 1,
                user: "Tell me about a time you led a project under a tight deadline.".into(),
                assistant: "I'd start by cutting scope, not quality — ship the core flow first and flag the rest.\n\n- At **Nimbus**, a 6-week checkout migration got compressed to 3; I re-scoped to the **top three merchant flows** and put the long tail behind a feature flag.\n- We hit the date with **zero Sev-1s**, and the deferred flows landed quietly two weeks later.\n- The lesson: visible progress beats hidden completeness — stakeholders forgive a smaller launch, never a missed one.".into(),
                streaming: false,
                input_tokens: 412,
                output_tokens: 148,
                error: false,
                auto_retried: false,
            },
            Turn {
                id: 2,
                user: "How do you decide what to cut when the deadline is fixed?".into(),
                assistant: "Rank by user impact per engineering day, then cut from the bottom until it fits.\n\n- Anything **irreversible** (data model, public API) stays; anything cosmetic goes behind a flag.\n- I make the cut list **public early** so nobody discovers a missing feature at launch.".into(),
                streaming: false,
                input_tokens: 655,
                output_tokens: 96,
                error: false,
                auto_retried: false,
            },
        ];
        self.next_turn_id = 3;
        self.transcript = "and thinking about that same project what would you say was the biggest technical risk you took".into();
        self.session_elapsed = Duration::from_secs(754);
        self.focus_mode = true;
        self.show_transcript = true;
    }

    fn demo_seed_resume(&mut self) {
        let base = "ALEX CARTER — Senior Backend Engineer\nNimbus Cloud (2019–now): led checkout-service rewrite (Rust), cut p99 40%…";
        let preset = self.resumes.add("Alex Carter — 2026", base, Some("AlexCarter.docx".into()));
        self.jd_text = "Staff Engineer, Payments Platform. Own reliability of the payment path; Rust or Go; distributed systems at scale.".into();
        let gen = self.resumes.add_generation(preset, base, &self.jd_text);
        if let Some(g) = self.resumes.generation_mut(gen) {
            g.generated_text = "## Alex Carter\n**Staff-level backend engineer** — payments, reliability, Rust.\n\n- Led the **checkout-service rewrite** at Nimbus: p99 −40%, zero-downtime cutover.\n- Designed idempotent retry layer handling **12M payments/day**.\n\n## Key changes\n- Led with payments-path reliability to mirror the JD's first requirement.".into();
            g.before_score = Some(ResumeScore {
                score: 61,
                verdict: "Decent match — payments depth is buried".into(),
                missing: vec!["idempotency".into(), "Kafka".into(), "on-call".into()],
                strengths: vec!["Rust".into(), "distributed systems".into()],
            });
            g.after_score = Some(ResumeScore {
                score: 88,
                verdict: "Strong match, minimal tailoring needed".into(),
                missing: vec!["Kafka".into()],
                strengths: vec!["Rust".into(), "payments".into(), "reliability".into()],
            });
        }
    }

    /// Scroll offset a capture scene wants applied to the surface's scroll
    /// area, so a scene can document content further down the form without
    /// resizing the window to fake it. `None` outside demo runs.
    pub(super) fn demo_scroll(&self) -> Option<f32> {
        let d = self.demo.as_ref()?;
        match d.scene {
            9 => Some(520.0),  // résumé: down to the score card
            13 => Some(240.0), // profile → panel tab: down to the sliders
            _ => None,
        }
    }

    /// Returns `false` when past the last scene (demo finished). Tall scenes
    /// grow the window so a whole form fits in one frame.
    fn demo_apply_scene(&mut self, ctx: &egui::Context, n: usize) -> bool {
        // Scroll offsets are owned by egui, so the one "scrolled" scene is
        // staged by making the window tall enough to show the rest of the
        // form instead. Every other scene keeps the real default size — the
        // gallery should show what the app actually looks like, and staging
        // profile/résumé tall made them look like they grow to fit content
        // when in fact they scroll.
        let tall = n == 3;
        self.settings.panel_height = if tall { 900.0 } else { 560.0 };
        // Only the dedicated hover scene shows the chrome; every other live
        // scene rests in the immersive state.
        if let Some(d) = self.demo.as_mut() {
            d.force_chrome = n == 5;
        }
        match n {
            0 => {
                self.set_collapsed(ctx, false);
                self.set_surface(ctx, None);
            }
            1 => self.set_collapsed(ctx, true),
            2 | 3 => {
                self.set_collapsed(ctx, false);
                self.set_surface(ctx, Some(Surface::Interview));
                if n == 3 {
                    self.attachments.push(Attachment {
                        name: "staff-eng-payments-JD.pdf".into(),
                        text: "Own reliability of the payment path…".into(),
                    });
                    self.attachments.push(Attachment {
                        name: "recruiter-notes.md".into(),
                        text: "Panel: 2 system design, 1 behavioural.".into(),
                    });
                }
            }
            4 | 5 => {
                self.attachments.clear();
                self.demo_seed_session();
                self.set_surface(ctx, Some(Surface::Interview));
            }
            6 => self.transcript_expanded = true,
            7 => {
                self.transcript_expanded = false;
                self.focus_mode = false;
            }
            8 | 9 => {
                if n == 8 {
                    self.demo_seed_resume();
                }
                self.resume_tab = ResumeTab::Build;
                self.set_surface(ctx, Some(Surface::Resume));
            }
            10 => {
                self.resume_tab = ResumeTab::Generations;
                self.set_surface(ctx, Some(Surface::Resume));
            }
            11..=13 => {
                self.profile_tab = match n {
                    11 => ProfileTab::Ai,
                    12 => ProfileTab::Prompts,
                    _ => ProfileTab::Panel,
                };
                self.set_surface(ctx, Some(Surface::Profile));
            }
            14 => {
                // Back to the idle launcher — the round trip the bar has to
                // survive without drifting.
                self.end_session();
                self.set_surface(ctx, None);
            }
            _ => return false,
        }
        self.resize_to_state(ctx);
        true
    }

    fn drive_demo(&mut self, ctx: &egui::Context) {
        if self.demo.is_none() {
            return;
        }
        ctx.request_repaint_after(Duration::from_millis(50));
        let shot = ctx.input(|i| {
            i.events.iter().rev().find_map(|e| match e {
                egui::Event::Screenshot { image, .. } => Some(image.clone()),
                _ => None,
            })
        });
        if let Some(image) = shot {
            let (out, scene) = {
                let d = self.demo.as_ref().unwrap();
                (d.out.clone(), d.scene)
            };
            // Geometry trace: the bar sits at the window's bottom edge, so
            // `bottom` must hold steady across scenes that only change height.
            if let Some(rect) = ctx.input(|i| i.viewport().outer_rect) {
                eprintln!(
                    "[geo] {:<24} pos=({:>6.0},{:>6.0}) size={:>5.0}x{:<5.0} bottom={:.0}",
                    DEMO_SCENES[scene],
                    rect.min.x,
                    rect.min.y,
                    rect.width(),
                    rect.height(),
                    rect.max.y
                );
            }
            save_png(&out.join(format!("{}.png", DEMO_SCENES[scene])), &image);
            let next = {
                let d = self.demo.as_mut().unwrap();
                d.scene += 1;
                d.since = Instant::now();
                d.requested = false;
                d.scene
            };
            if !self.demo_apply_scene(ctx, next) {
                self.demo = None;
                ctx.send_viewport_cmd(ViewportCommand::Close);
            }
            return;
        }
        let d = self.demo.as_ref().unwrap();
        if !d.requested && d.since.elapsed() > Duration::from_millis(900) {
            self.demo.as_mut().unwrap().requested = true;
            ctx.send_viewport_cmd(ViewportCommand::Screenshot);
        }
    }

    // ── Events + timers ──────────────────────────────────────────────────────

    fn drain_events(&mut self) {
        while let Ok(ev) = self.ui_rx.try_recv() {
            match ev {
                UiEvent::Transcript(seg) => self.on_transcript(seg),
                UiEvent::Status(s) => self.status = s,
                UiEvent::AiChunk { turn, text } => self.on_ai_chunk(turn, text),
                UiEvent::AiUsage { turn, input, output } => {
                    if let Some(t) = self.turns.iter_mut().find(|t| t.id == turn) {
                        t.input_tokens = input;
                        t.output_tokens = output;
                    }
                }
                UiEvent::AiDone { turn } => self.on_ai_done(turn),
                UiEvent::AiError { turn, message } => self.on_ai_error(turn, message),
            }
        }
    }

    fn target_of(&self, turn: u64) -> AiTarget {
        self.ai_targets.get(&turn).copied().unwrap_or(AiTarget::Turn)
    }

    fn on_ai_chunk(&mut self, turn: u64, text: String) {
        match self.target_of(turn) {
            AiTarget::Turn => {
                if let Some(t) = self.turns.iter_mut().find(|t| t.id == turn) {
                    t.assistant.push_str(&text);
                }
            }
            AiTarget::Generation(gen) => {
                if let Some(g) = self.resumes.generation_mut(gen) {
                    g.generated_text.push_str(&text);
                }
            }
            AiTarget::Score { .. } => self.score_buf.push_str(&text),
        }
    }

    fn on_ai_done(&mut self, turn: u64) {
        match self.target_of(turn) {
            AiTarget::Turn => {
                if let Some(t) = self.turns.iter_mut().find(|t| t.id == turn) {
                    t.streaming = false;
                }
            }
            AiTarget::Generation(gen) => {
                self.active_generation = None;
                self.resumes.save_generations();
                // A fresh tailoring deserves a fresh score — chain the "after"
                // pass so the history row can show a real delta.
                let has_jd = self.resumes.generation(gen).is_some_and(|g| !g.jd.trim().is_empty());
                if has_jd {
                    self.start_score(gen, true);
                }
            }
            AiTarget::Score { generation, after } => {
                let parsed = ResumeScore::parse(&self.score_buf);
                self.score_buf.clear();
                self.scoring = None;
                if let Some(g) = self.resumes.generation_mut(generation) {
                    if after {
                        g.after_score = Some(parsed);
                    } else {
                        g.before_score = Some(parsed);
                    }
                }
                self.resumes.save_generations();
            }
        }
        self.ai_targets.remove(&turn);
        self.backend.finish_ai(turn);
    }

    /// Transient failures (rate limit / overload / dropped connection) get one
    /// silent retry after a short grace; anything else — or a second failure —
    /// lands in the turn as an error line.
    fn on_ai_error(&mut self, turn: u64, message: String) {
        self.backend.finish_ai(turn);
        match self.target_of(turn) {
            AiTarget::Generation(gen) => {
                if let Some(g) = self.resumes.generation_mut(gen) {
                    g.generated_text.push_str(&format!("\n\n⚠ {message}"));
                }
                self.active_generation = None;
                self.ai_targets.remove(&turn);
                self.resumes.save_generations();
                return;
            }
            AiTarget::Score { .. } => {
                self.scoring = None;
                self.score_buf.clear();
                self.status = format!("Scoring failed: {message}");
                self.ai_targets.remove(&turn);
                return;
            }
            AiTarget::Turn => {}
        }
        self.ai_targets.remove(&turn);
        let Some(t) = self.turns.iter_mut().find(|t| t.id == turn) else { return };
        if !t.auto_retried && is_transient_error(&message) {
            t.auto_retried = true;
            t.assistant.clear();
            // Stay "streaming" so the focus card keeps its thinking row
            // (relabelled "Retrying…") instead of flashing an error.
            t.streaming = true;
            self.auto_retry = Some((turn, Instant::now()));
            return;
        }
        if !t.assistant.is_empty() {
            t.assistant.push_str("\n\n");
        }
        t.assistant.push_str(&format!("⚠ {message}"));
        t.error = true;
        t.streaming = false;
    }

    fn fire_due_auto_retry(&mut self) {
        if let Some((turn, at)) = self.auto_retry {
            if at.elapsed() >= AUTO_RETRY_DELAY {
                self.auto_retry = None;
                self.retry_turn(turn);
            }
        }
    }

    fn on_transcript(&mut self, seg: String) {
        if self.force_send_next {
            self.force_send_next = false;
            self.send_question(seg);
            return;
        }
        if !self.transcript.is_empty() {
            self.transcript.push(' ');
        }
        self.transcript.push_str(seg.trim());
        self.pending_since = Some(Instant::now());
    }

    fn maybe_auto_send(&mut self) {
        if !self.settings.auto_send || !self.backend.is_recording() {
            return;
        }
        let Some(since) = self.pending_since else { return };
        if self.transcript.trim().is_empty() {
            return;
        }
        if since.elapsed() >= Duration::from_millis(self.settings.auto_send_silence_ms)
            && TranscriptFilter::seems_complete(&self.transcript)
        {
            let q = std::mem::take(&mut self.transcript);
            self.pending_since = None;
            self.focus_offset = 0;
            self.send_question(q);
        }
    }

    // ── Actions ────────────────────────────────────────────────────────────

    fn send_question(&mut self, text: String) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        let id = self.next_turn_id;
        self.next_turn_id += 1;
        let history = self.history_before(self.turns.len());
        self.turns.push(Turn {
            id,
            user: text.clone(),
            assistant: String::new(),
            streaming: true,
            input_tokens: 0,
            output_tokens: 0,
            error: false,
            auto_retried: false,
        });
        self.focus_offset = 0;
        let req = self.make_request(text, history, 2048);
        self.backend.stream_ai(id, req);
    }

    /// Re-run the question of an existing turn in place — Retry, the model
    /// switcher, and the automatic transient-error retry all land here.
    fn retry_turn(&mut self, id: u64) {
        let Some(idx) = self.turns.iter().position(|t| t.id == id) else { return };
        let text = self.turns[idx].user.clone();
        let history = self.history_before(idx);
        {
            let t = &mut self.turns[idx];
            t.assistant.clear();
            t.error = false;
            t.streaming = true;
        }
        let req = self.make_request(text, history, 2048);
        self.backend.stream_ai(id, req);
    }

    fn stop_turn(&mut self, id: u64) {
        self.backend.cancel_ai(id);
        if let Some(t) = self.turns.iter_mut().find(|t| t.id == id) {
            t.streaming = false;
        }
        if self.auto_retry.map(|(turn, _)| turn) == Some(id) {
            self.auto_retry = None;
        }
    }

    fn make_request(&self, text: String, history: Vec<(String, String)>, max_tokens: u32) -> AiRequest {
        AiRequest {
            text,
            model: self.settings.selected_model.clone(),
            system_prompt: prompt::session_system_prompt(&self.settings, &self.prompts),
            history,
            keys: self.settings.provider_keys(),
            max_tokens,
            image_base64: None,
        }
    }

    /// Everything attached to this session: the chosen résumé plus any
    /// context files, in the order the AI should read them.
    fn session_attachments(&self) -> Vec<Attachment> {
        let mut out = Vec::new();
        if let Some(p) = self.resumes.active() {
            if !p.content.trim().is_empty() {
                out.push(Attachment { name: format!("Résumé — {}", p.name), text: p.content.clone() });
            }
        }
        out.extend(self.attachments.iter().cloned());
        out
    }

    /// Context anchor + up to the last 6 completed exchanges before `idx`.
    fn history_before(&self, idx: usize) -> Vec<(String, String)> {
        let mut history = prompt::context_anchor_with(&self.settings, &self.session_attachments());
        let recent: Vec<&Turn> = self.turns[..idx.min(self.turns.len())]
            .iter()
            .filter(|t| !t.streaming && !t.error && !t.assistant.is_empty())
            .collect();
        let start = recent.len().saturating_sub(6);
        for t in &recent[start..] {
            history.push((t.user.clone(), t.assistant.clone()));
        }
        history
    }

    fn start_interview(&mut self, ctx: &egui::Context) {
        self.surface = Some(Surface::Interview);
        self.focus_mode = true;
        self.show_transcript = true;
        self.start_recording(self.settings.audio_source);
        self.resize_to_state(ctx);
    }

    fn stop_recording(&mut self) {
        self.backend.stop_recording();
        if let Some(since) = self.recording_since.take() {
            self.session_elapsed += since.elapsed();
        }
    }

    fn toggle_recording(&mut self, ctx: &egui::Context) {
        if self.backend.is_recording() {
            self.stop_recording();
        } else {
            self.start_interview(ctx);
        }
    }

    fn start_recording(&mut self, source: AudioSource) {
        let key = self.settings.stt_key().to_string();
        self.backend.start_recording(source, self.settings.stt_provider, key, self.settings.stt_model.clone());
        if self.recording_since.is_none() {
            self.recording_since = Some(Instant::now());
        }
    }

    fn end_session(&mut self) {
        self.backend.stop_recording();
        self.backend.cancel_all_ai();
        self.recording_since = None;
        self.session_elapsed = Duration::ZERO;
        self.turns.clear();
        self.transcript.clear();
        self.pending_since = None;
        self.focus_offset = 0;
        self.transcript_expanded = false;
        self.auto_retry = None;
    }

    /// System prompt for a résumé task, honoring a saved preset override.
    fn resume_prompt(&self, kind: PromptKind, default: &str) -> String {
        self.prompts.active(kind).map(|p| p.content.clone()).unwrap_or_else(|| default.to_string())
    }

    /// Start a tailoring run: snapshot the résumé + JD as a generation, then
    /// stream the rewrite into it. Scoring of the result is chained on
    /// completion so the history row gets a before/after delta.
    fn tailor_resume(&mut self) {
        if self.active_generation.is_some() {
            return;
        }
        let Some(preset) = self.resumes.active().cloned() else {
            self.status = "Add a résumé first — upload one or paste it in.".into();
            return;
        };
        if preset.content.trim().is_empty() {
            self.status = "That résumé is empty.".into();
            return;
        }
        let jd = self.jd_text.trim().to_string();
        let gen = self.resumes.add_generation(preset.id, &preset.content, &jd);
        self.active_generation = Some(gen);
        self.resume_tab = ResumeTab::Build;

        // Score the original first so the delta has a baseline.
        if !jd.is_empty() {
            self.start_score(gen, false);
        }

        let id = self.next_turn_id;
        self.next_turn_id += 1;
        self.ai_targets.insert(id, AiTarget::Generation(gen));
        let req = AiRequest {
            text: resumes::generation_user_prompt(&preset.content, &jd),
            model: self.settings.selected_model.clone(),
            system_prompt: self
                .resume_prompt(PromptKind::ResumeGeneration, resumes::DEFAULT_GENERATION_PROMPT),
            history: Vec::new(),
            keys: self.settings.provider_keys(),
            max_tokens: 4096,
            image_base64: None,
        };
        self.backend.stream_ai(id, req);
    }

    /// Score a generation's résumé against its JD. `after` picks which text
    /// gets scored — the original snapshot or the tailored output.
    fn start_score(&mut self, generation: u64, after: bool) {
        let Some(g) = self.resumes.generation(generation) else { return };
        let text = if after { g.generated_text.clone() } else { g.base_text.clone() };
        let jd = g.jd.clone();
        if text.trim().is_empty() || jd.trim().is_empty() {
            return;
        }
        let id = self.next_turn_id;
        self.next_turn_id += 1;
        self.ai_targets.insert(id, AiTarget::Score { generation, after });
        self.scoring = Some((generation, after));
        self.score_buf.clear();
        let req = AiRequest {
            text: resumes::scoring_user_prompt(&text, &jd),
            model: self.settings.selected_model.clone(),
            system_prompt: self
                .resume_prompt(PromptKind::ResumeScoring, resumes::DEFAULT_SCORING_PROMPT),
            history: Vec::new(),
            keys: self.settings.provider_keys(),
            max_tokens: 512,
            image_base64: None,
        };
        self.backend.stream_ai(id, req);
    }

    /// Score the active résumé on its own, without tailoring — the Mac
    /// panel's standalone "score against this JD" action. Recorded as a
    /// generation with no output so the history keeps every check.
    fn score_only(&mut self) {
        if self.scoring.is_some() {
            return;
        }
        let Some(preset) = self.resumes.active().cloned() else {
            self.status = "Add a résumé first.".into();
            return;
        };
        if self.jd_text.trim().is_empty() {
            self.status = "Paste a job description to score against.".into();
            return;
        }
        let gen = self.resumes.add_generation(preset.id, &preset.content, self.jd_text.trim());
        self.open_generation = Some(gen);
        self.start_score(gen, false);
    }

    /// The generation the Build tab is currently showing: the streaming one,
    /// else the one being scored, else the most recent.
    fn current_generation(&self) -> Option<u64> {
        self.active_generation
            .or(self.scoring.map(|(g, _)| g))
            .or_else(|| self.resumes.generations.first().map(|g| g.id))
    }

    // ── File import ─────────────────────────────────────────────────────────

    /// Open a native picker filtered to the formats we can read.
    fn pick_files(multiple: bool) -> Vec<PathBuf> {
        let dialog = rfd::FileDialog::new().add_filter(
            "Documents (PDF, DOCX, RTF, TXT, MD)",
            &copilot_core::files::SUPPORTED_EXTENSIONS,
        );
        if multiple {
            dialog.pick_files().unwrap_or_default()
        } else {
            dialog.pick_file().into_iter().collect()
        }
    }

    /// Import `path` into the résumé library and make it active.
    fn import_resume(&mut self, path: &Path) {
        match copilot_core::files::import(path) {
            Ok(imported) => {
                let name = copilot_core::files::suggested_name(path);
                let filename = path.file_name().map(|f| f.to_string_lossy().to_string());
                self.resumes.add(&name, &imported.text, filename);
                self.show_resume_library = false;
                self.status = format!("Imported “{name}”.");
            }
            Err(e) => self.status = format!("{e}"),
        }
    }

    /// Import files as session context attachments (JD, notes, briefings).
    fn import_attachments(&mut self, paths: &[PathBuf]) {
        for path in paths {
            let name = path.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
            if self.attachments.iter().any(|a| a.name == name) {
                continue;
            }
            match copilot_core::files::import(path) {
                Ok(imported) => self.attachments.push(Attachment { name, text: imported.text }),
                Err(e) => self.status = format!("{name}: {e}"),
            }
        }
    }

    /// Save text to a file the user picks. Used for tailored résumé output.
    fn save_text_as(&mut self, suggested: &str, text: &str) {
        let path = rfd::FileDialog::new()
            .set_file_name(suggested)
            .add_filter("Markdown", &["md"])
            .add_filter("Text", &["txt"])
            .save_file();
        if let Some(path) = path {
            match std::fs::write(&path, text) {
                Ok(()) => self.status = format!("Saved to {}", path.display()),
                Err(e) => self.status = format!("Could not save: {e}"),
            }
        }
    }

    fn set_surface(&mut self, ctx: &egui::Context, surface: Option<Surface>) {
        self.surface = surface;
        self.resize_to_state(ctx);
    }

    fn set_collapsed(&mut self, ctx: &egui::Context, collapsed: bool) {
        self.collapsed = collapsed;
        self.resize_to_state(ctx);
    }

    /// The window size for the current state.
    fn target_size(&self) -> Vec2 {
        if self.collapsed {
            PILL_SIZE
        } else if self.surface.is_none() {
            if self.live() {
                // Live controls need room for the follow-up field.
                Vec2::new(self.settings.panel_width.max(360.0), BAR_HEIGHT)
            } else {
                // Idle launcher: hug the logo + three pills — a wide empty
                // bar with icons floating in the middle looks broken.
                Vec2::new(self.launcher_w, BAR_HEIGHT)
            }
        } else {
            Vec2::new(self.settings.panel_width, self.settings.panel_height)
        }
    }

    /// Resize the window, keeping its **bottom edge** where it is.
    ///
    /// The bar lives at the bottom of the window and surfaces open upward
    /// above it. A window is positioned by its top-left, so resizing alone
    /// would drag the bar up to meet the old top edge — the bar would appear
    /// to jump every time a surface opened or closed. Compensating the y
    /// keeps the bar visually pinned, which is what the macOS panel does.
    fn resize_to_state(&mut self, ctx: &egui::Context) {
        let size = self.target_size();
        let bottom = ctx.input(|i| i.viewport().outer_rect.map(|r| r.max.y));
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));

        // Derive the new top from the *observed* bottom rather than nudging by
        // a delta. Several callers can resize in one frame (set_surface then
        // the demo driver, say) and the viewport rect doesn't update until the
        // frame ends, so an incremental adjustment would apply twice. Solving
        // for an absolute position is idempotent: every call in the frame
        // reads the same bottom and the last one lands correctly.
        if let Some(bottom) = bottom {
            let y = bottom - size.y;
            if (y - self.settings.panel_y).abs() > 0.5 {
                self.settings.panel_y = y;
                ctx.send_viewport_cmd(ViewportCommand::OuterPosition(pos2(self.settings.panel_x, y)));
            }
        }
    }

    fn live(&self) -> bool {
        self.backend.is_recording() || !self.turns.is_empty()
    }

    /// Hover-reveal, matching the macOS shell's `chromeHovering`.
    ///
    /// Once a session is live, everything that isn't the question and answer
    /// — the session header, the quick-action chips, the composer bar, the
    /// resize grip — fades out, and comes back while the cursor is over the
    /// window. The reveal is opacity-only and each piece keeps its slot in
    /// the layout, so nothing reflows and the answer never shifts under the
    /// reader's eyes.
    fn update_chrome_reveal(&mut self, ctx: &egui::Context) {
        // Immersive only on the live interview itself. Not with the bar alone
        // (the composer *is* the UI there, so fading it leaves a blank strip),
        // and not on the résumé/profile surfaces — a live session in the
        // background shouldn't strip the chrome off a form being filled in.
        let immersive =
            self.live() && self.surface == Some(Surface::Interview) && !self.collapsed;
        let wanted = if let Some(d) = self.demo.as_ref() {
            // A capture run must not depend on where the physical mouse
            // happens to be sitting, or scenes come out non-deterministically.
            !immersive || d.force_chrome
        } else {
            !immersive
                || ctx.input(|i| i.pointer.has_pointer())
                // Never yank the bar out from under a half-typed follow-up,
                // and hold still while a menu is open (the pointer may be
                // over the popup, which is its own layer).
                || !self.input.trim().is_empty()
                || ctx.memory(|m| m.any_popup_open())
        };

        self.chrome_alpha = ctx.animate_bool_with_time(egui::Id::new("chrome-reveal"), wanted, 0.18);
        self.chrome_interactive = wanted;
    }

    fn session_secs(&self) -> u64 {
        let live = self.recording_since.map(|s| s.elapsed()).unwrap_or(Duration::ZERO);
        (self.session_elapsed + live).as_secs()
    }

    // ── Copy feedback ────────────────────────────────────────────────────────

    fn flash(&mut self, id: egui::Id) {
        self.copied.insert(id, Instant::now());
    }

    fn flashed(&self, id: egui::Id) -> bool {
        self.copied.get(&id).is_some_and(|t| t.elapsed() < COPY_FLASH)
    }

    fn copy_to_clipboard(&mut self, id: egui::Id, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        if let Ok(mut cb) = arboard::Clipboard::new() {
            if cb.set_text(text.to_string()).is_ok() {
                self.flash(id);
            }
        }
    }

    /// A small "Copy" chip that flips to a green "✓ Copied" for a moment.
    fn copy_chip(&mut self, ui: &mut egui::Ui, key: egui::Id, text: &str) {
        let lit = self.flashed(key);
        let label = if lit { "Copied" } else { "Copy" };
        let resp = theme::chip(ui, label, None).on_hover_text("Copy to clipboard");
        if lit {
            ui.painter().rect_stroke(
                resp.rect,
                Rounding::same(resp.rect.height() / 2.0),
                Stroke::new(0.8, theme::GREEN.gamma_multiply(0.8)),
            );
        }
        if resp.clicked() {
            self.copy_to_clipboard(key, text);
        }
    }

    // ── Hotkeys ──────────────────────────────────────────────────────────────

    fn handle_hotkeys(&mut self, ctx: &egui::Context) {
        let actions: Vec<(HotkeyAction, bool)> = match &self.hotkeys {
            Some(hk) => hk.poll(),
            None => return,
        };
        for (action, pressed) in actions {
            match action {
                HotkeyAction::QuickAsk => {
                    if pressed {
                        if !self.backend.is_recording() {
                            self.transcript.clear();
                            self.start_recording(AudioSource::Microphone);
                            self.quick_ask_started = true;
                            self.set_collapsed(ctx, false);
                            self.set_surface(ctx, Some(Surface::Interview));
                        }
                    } else if self.quick_ask_started {
                        self.quick_ask_started = false;
                        self.stop_recording();
                        self.force_send_next = true;
                    }
                    continue;
                }
                _ if !pressed => continue,
                HotkeyAction::Toggle => {
                    let c = !self.collapsed;
                    self.set_collapsed(ctx, c);
                }
                HotkeyAction::Record => self.toggle_recording(ctx),
                HotkeyAction::ExplainClipboard => self.explain_clipboard(ctx),
                HotkeyAction::MoveLeft => self.nudge_position(ctx, -MOVE_STEP, 0.0),
                HotkeyAction::MoveRight => self.nudge_position(ctx, MOVE_STEP, 0.0),
                HotkeyAction::MoveUp => self.nudge_position(ctx, 0.0, -MOVE_STEP),
                HotkeyAction::MoveDown => self.nudge_position(ctx, 0.0, MOVE_STEP),
                HotkeyAction::ResizeWider => self.resize_panel(ctx, RESIZE_STEP, 0.0),
                HotkeyAction::ResizeNarrower => self.resize_panel(ctx, -RESIZE_STEP, 0.0),
                HotkeyAction::ResizeTaller => self.resize_panel(ctx, 0.0, RESIZE_STEP),
                HotkeyAction::ResizeShorter => self.resize_panel(ctx, 0.0, -RESIZE_STEP),
            }
        }
    }

    fn explain_clipboard(&mut self, ctx: &egui::Context) {
        match arboard::Clipboard::new().and_then(|mut c| c.get_text()) {
            Ok(text) if !text.trim().is_empty() => {
                self.set_surface(ctx, Some(Surface::Interview));
                self.send_question(format!("Explain the following clearly and concisely:\n\n{text}"));
            }
            Ok(_) => self.status = "Clipboard is empty.".into(),
            Err(e) => self.status = format!("Couldn't read clipboard: {e}"),
        }
    }

    fn nudge_position(&mut self, ctx: &egui::Context, dx: f32, dy: f32) {
        self.settings.panel_x += dx;
        self.settings.panel_y += dy;
        ctx.send_viewport_cmd(ViewportCommand::OuterPosition(pos2(self.settings.panel_x, self.settings.panel_y)));
    }

    fn resize_panel(&mut self, ctx: &egui::Context, dw: f32, dh: f32) {
        self.settings.panel_width = (self.settings.panel_width + dw).max(MIN_PANEL.x);
        self.settings.panel_height = (self.settings.panel_height + dh).max(MIN_PANEL.y);
        self.resize_to_state(ctx);
    }

    // ── Persistence ────────────────────────────────────────────────────────

    fn sync_and_persist_geometry(&mut self, ctx: &egui::Context) {
        ctx.input(|i| {
            let vp = i.viewport();
            if let Some(outer) = vp.outer_rect {
                self.settings.panel_x = outer.min.x;
                self.settings.panel_y = outer.min.y;
            }
            // Only remember the size while a full surface is open, so the pill
            // and bar-only heights never overwrite the user's panel size.
            if !self.collapsed && self.surface.is_some() {
                if let Some(inner) = vp.inner_rect {
                    self.settings.panel_width = inner.width();
                    self.settings.panel_height = inner.height();
                }
            }
        });
        let geo = (self.settings.panel_x, self.settings.panel_y, self.settings.panel_width, self.settings.panel_height);
        if geo != self.last_saved_geo && self.last_save.elapsed() > Duration::from_secs(1) {
            self.last_saved_geo = geo;
            self.last_save = Instant::now();
            self.persist();
        }
    }

    fn persist(&self) {
        let _ = self.settings.save(&self.settings_path);
    }
}

impl eframe::App for App {
    fn clear_color(&self, _v: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn save(&mut self, _s: &mut dyn eframe::Storage) {
        self.persist();
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if !self.overlay_applied {
            self.overlay_applied = crate::overlay::apply_overlay_flags();
        }
        self.drive_demo(ctx);
        self.handle_hotkeys(ctx);
        self.drain_events();
        self.fire_due_auto_retry();
        self.maybe_auto_send();
        self.sync_and_persist_geometry(ctx);
        self.copied.retain(|_, t| t.elapsed() < Duration::from_secs(5));
        let t = ctx.input(|i| i.time);

        // Whole-overlay opacity and card-background opacity are independent,
        // exactly like the two macOS ⋯ sliders: fade everything, or just the
        // panel behind the text.
        let fg = self.settings.opacity.clamp(0.2, 1.0);
        let bg = self.settings.background_opacity.clamp(0.2, 1.0);
        self.update_chrome_reveal(ctx);

        if self.collapsed {
            egui::CentralPanel::default()
                .frame(egui::Frame::none())
                .show(ctx, |ui| {
                    ui.set_opacity(fg);
                    self.draw_pill(ui, ctx, t, bg);
                });
        } else {
            egui::TopBottomPanel::bottom("composer")
                .frame(egui::Frame::none().outer_margin(Margin::same(6.0)))
                .show_separator_line(false)
                .show(ctx, |ui| {
                    ui.set_opacity(fg);
                    // Reserves its slot even while hidden, so revealing the
                    // bar never reflows the answer above it.
                    let (alpha, live) = (self.chrome_alpha, self.chrome_interactive);
                    chrome_layer(ui, alpha, live, |ui| {
                        theme::card_alpha(24.0, bg).inner_margin(Margin::symmetric(8.0, 6.0)).show(ui, |ui| {
                            self.draw_composer(ui, ctx, t);
                        });
                    });
                });

            // Live session: the header floats as its own bar above the card,
            // so hiding it leaves transparent space instead of a blank band
            // inside the answer card.
            if self.surface == Some(Surface::Interview) && self.live() {
                let (alpha, live) = (self.chrome_alpha, self.chrome_interactive);
                egui::TopBottomPanel::top("session-header")
                    .frame(egui::Frame::none().outer_margin(Margin { left: 6.0, right: 6.0, top: 6.0, bottom: 0.0 }))
                    .show_separator_line(false)
                    .show(ctx, |ui| {
                        ui.set_opacity(fg);
                        chrome_layer(ui, alpha, live, |ui| {
                            theme::card_alpha(16.0, bg)
                                .inner_margin(Margin::symmetric(14.0, 7.0))
                                .show(ui, |ui| {
                                    ui.set_min_width(ui.available_width());
                                    self.draw_session_header(ui, ctx);
                                });
                        });
                    });
            }

            if self.surface.is_some() {
                egui::CentralPanel::default()
                    .frame(egui::Frame::none().outer_margin(Margin { left: 6.0, right: 6.0, top: 6.0, bottom: 0.0 }))
                    .show(ctx, |ui| {
                        ui.set_opacity(fg);
                        // Size the card body to the panel MINUS the frame's
                        // own margins. Measuring inside the frame instead
                        // made the card overflow the panel by its margins,
                        // which pushed the scroll viewport's bottom past the
                        // visible edge — the last row was clipped off rather
                        // than reachable by scrolling.
                        let card = theme::card_alpha(16.0, bg);
                        let m = card.inner_margin;
                        // Clamped: on the frame where the window is still
                        // pill-sized mid-transition the panel is smaller than
                        // the margins, and a negative size panics egui.
                        let body = (ui.available_size() - vec2(m.left + m.right, m.top + m.bottom))
                            .max(Vec2::splat(1.0));
                        card.show(ui, |ui| {
                            ui.set_min_size(body);
                            ui.set_max_size(body);
                            match self.surface {
                                Some(Surface::Interview) => self.draw_interview(ui, ctx, t),
                                Some(Surface::Resume) => self.draw_resume(ui),
                                Some(Surface::Profile) => self.draw_settings(ui, ctx),
                                None => {}
                            }
                        });
                    });
                self.draw_resize_grip(ctx);
            }
        }

        let busy = self.backend.is_recording()
            || self.pending_since.is_some()
            || self.active_generation.is_some()
            || self.scoring.is_some()
            || self.auto_retry.is_some()
            || self.turns.iter().any(|t| t.streaming);
        // Always animate a little so hover transitions stay smooth.
        ctx.request_repaint_after(Duration::from_millis(if busy { 60 } else { 140 }));
    }
}

// ── Composer + shell ─────────────────────────────────────────────────────────

impl App {
    fn draw_pill(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, t: f64, bg: f32) {
        let rec = self.backend.is_recording();
        ui.centered_and_justified(|ui| {
            theme::card_alpha(15.0, bg).inner_margin(Margin::same(6.0)).show(ui, |ui| {
                let color = if rec { theme::RED } else { Color32::WHITE };
                let resp = theme::waveform(ui, t, rec, color, 28.0);
                if resp.drag_started() {
                    ctx.send_viewport_cmd(ViewportCommand::StartDrag);
                }
                if resp.clicked() {
                    self.set_collapsed(ctx, false);
                }
            });
        });
    }

    fn draw_composer(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, t: f64) {
        // Standalone launcher (no surface open, no live session): the bar
        // hugs its content and the window shrinks to match. Otherwise it
        // spans the panel so its edges line up with the surface card above.
        let hug = self.surface.is_none() && !self.live();
        let row = ui.horizontal(|ui| {
            ui.set_min_height(44.0);
            if !hug {
                ui.set_min_width(ui.available_width());
            }
            ui.add_space(4.0);
            let rec = self.backend.is_recording();
            let wf = theme::waveform(ui, t, rec, if rec { theme::RED } else { Color32::WHITE }, 30.0);
            if wf.drag_started() {
                ctx.send_viewport_cmd(ViewportCommand::StartDrag);
            }
            if wf.clicked() {
                self.set_collapsed(ctx, true);
            }
            ui.add(egui::Separator::default().vertical().spacing(10.0));

            if self.live() {
                self.draw_live_composer(ui);
            } else {
                self.draw_surface_icons(ui, ctx);
            }
        });

        // Measure the launcher row and resize the window to fit it exactly,
        // so the bar hugs its pills under any font (Segoe UI on Windows is
        // wider than SF Pro) or UI zoom instead of assuming a fixed width.
        if hug && !self.collapsed {
            let want = row.response.rect.width() + BAR_CHROME_W;
            if (want - self.launcher_w).abs() > 1.0 {
                self.launcher_w = want;
                self.resize_to_state(ctx);
            }
        }
    }

    /// The three surface pills (icon + label inline), sitting right after
    /// the brand — a tight launcher row, not icons adrift in empty space.
    fn draw_surface_icons(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        ui.add_space(2.0);
        let needs_key = self.settings.provider_keys_missing();
        let items = [
            (Surface::Interview, IconKind::Monitor, "Interview", false),
            (Surface::Resume, IconKind::Document, "Résumé", false),
            (Surface::Profile, IconKind::Person, "Profile", needs_key),
        ];
        for (surface, icon, label, attention) in items {
            let active = self.surface == Some(surface);
            let resp = surface_pill(ui, icon, label, active, attention);
            let resp = if attention {
                resp.on_hover_text("Add an API key here first")
            } else {
                resp
            };
            if resp.clicked() {
                // Toggle: clicking the open surface closes it back to bar-only.
                self.set_surface(ctx, if active { None } else { Some(surface) });
            }
        }
    }

    /// During a live session: follow-up field + model + pause/resume + send.
    fn draw_live_composer(&mut self, ui: &mut egui::Ui) {
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            let can_send = !self.input.trim().is_empty() || !self.transcript.trim().is_empty();
            let (send_tint, send_fill) = if can_send {
                (theme::INK_INVERSE, Some(Color32::WHITE))
            } else {
                (theme::INK_MUTED, None)
            };
            if theme::icon_button(ui, theme::Icon::ArrowUp, send_tint, send_fill, 30.0)
                .on_hover_text("Send now (Enter)")
                .clicked()
                && can_send
            {
                self.submit_composer();
            }
            let rec = self.backend.is_recording();
            let (icon, tint, fill, tip) = if rec {
                (theme::Icon::Pause, theme::RED, Some(theme::RED.gamma_multiply(0.22)), "Pause listening")
            } else {
                (theme::Icon::Play, theme::GREEN, Some(theme::GREEN.gamma_multiply(0.20)), "Resume listening")
            };
            if theme::icon_button(ui, icon, tint, fill, 30.0).on_hover_text(tip).clicked() {
                if rec {
                    self.stop_recording();
                } else {
                    self.start_recording(self.settings.audio_source);
                }
            }
            self.model_picker(ui);
            let resp = ui.add_sized(
                vec2(ui.available_width().max(80.0), 30.0),
                egui::TextEdit::singleline(&mut self.input)
                    .hint_text("Type a follow-up…")
                    .margin(Margin::symmetric(10.0, 7.0))
                    .vertical_align(Align::Center),
            );
            if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                self.submit_composer();
                ui.memory_mut(|m| m.request_focus(resp.id));
            }
        });
    }

    fn submit_composer(&mut self) {
        let q = if !self.input.trim().is_empty() {
            std::mem::take(&mut self.input)
        } else {
            self.pending_since = None;
            std::mem::take(&mut self.transcript)
        };
        self.send_question(q);
    }

    fn model_picker(&mut self, ui: &mut egui::Ui) {
        // Trailing spaces reserve room for the painted chevron (the `▾`
        // glyph is tofu in several fallback fonts).
        let label = format!("{}    ", model_name(&self.settings.selected_model));
        let resp = ui
            .menu_button(RichText::new(label).size(11.0).color(theme::INK2), |ui| {
                egui::ScrollArea::vertical().max_height(320.0).show(ui, |ui| {
                    let mut last = "";
                    for m in available_models() {
                        if m.provider != last {
                            ui.add_space(2.0);
                            ui.label(RichText::new(m.provider.to_uppercase()).size(9.0).color(theme::INK3).strong());
                            last = m.provider;
                        }
                        if ui.selectable_label(self.settings.selected_model == m.id, m.name).clicked() {
                            self.settings.selected_model = m.id.to_string();
                            self.persist();
                            ui.close_menu();
                        }
                    }
                });
            })
            .response;
        theme::overlay_chevron(ui.painter(), resp.rect, theme::INK3);
    }

    /// Bottom-right drag grip (the Mac corner resize) — drawn over the window
    /// corner whenever a surface is open, so the panel can be resized with the
    /// mouse instead of only Ctrl+Shift+arrows.
    fn draw_resize_grip(&self, ctx: &egui::Context) {
        egui::Area::new(egui::Id::new("resize-grip"))
            .anchor(egui::Align2::RIGHT_BOTTOM, vec2(-7.0, -7.0))
            .order(egui::Order::Foreground)
            .show(ctx, |ui| {
                // Fades with the rest of the chrome, but stays draggable: a
                // resize in flight must not be dropped if the cursor slips
                // outside the window bounds mid-drag.
                ui.set_opacity(self.chrome_alpha);
                let (rect, resp) = ui.allocate_exact_size(Vec2::splat(14.0), Sense::drag());
                if resp.drag_started() {
                    ctx.send_viewport_cmd(ViewportCommand::BeginResize(egui::viewport::ResizeDirection::SouthEast));
                }
                let hov = ui
                    .ctx()
                    .animate_bool_with_time(resp.id.with("hover"), resp.hovered(), theme::HOVER_T);
                let c = theme::INK3.lerp_to_gamma(theme::INK, hov);
                let p = ui.painter();
                for i in 0..3 {
                    let off = 4.0 * i as f32;
                    p.line_segment(
                        [pos2(rect.right() - 1.0, rect.bottom() - 9.0 + off - 2.0), pos2(rect.right() - 9.0 + off - 2.0, rect.bottom() - 1.0)],
                        Stroke::new(1.2, c.gamma_multiply(0.8)),
                    );
                }
                resp.on_hover_cursor(egui::CursorIcon::ResizeSouthEast);
            });
    }

    // ── Interview surface ────────────────────────────────────────────────────

    fn draw_interview(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, t: f64) {
        if self.live() {
            self.draw_live_session(ui, ctx, t);
        } else {
            self.draw_interview_setup(ui, ctx);
        }
    }

    // ── Live session ─────────────────────────────────────────────────────────

    /// Session header — mode + ⋯ menu. During a live session this is drawn as
    /// its own floating bar *above* the card (see `update`), not inside it:
    /// hidden chrome still reserves its slot so nothing reflows, and keeping
    /// that slot outside the card means the reserved space is transparent
    /// rather than a blank band across the top of the answer.
    fn draw_session_header(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        ui.horizontal(|ui| {
            theme::dot(ui, theme::mode_color(self.settings.session_mode), 3.5);
            ui.label(
                RichText::new(self.settings.session_mode.display_name())
                    .size(13.0)
                    .color(theme::mode_color(self.settings.session_mode))
                    .strong(),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let resp = ui.menu_button("      ", |ui| self.session_menu(ui, ctx)).response;
                theme::overlay_dots(ui.painter(), resp.rect, theme::INK2);
            });
        });
    }

    fn draw_live_session(&mut self, ui: &mut egui::Ui, _ctx: &egui::Context, t: f64) {
        let (alpha, live) = (self.chrome_alpha, self.chrome_interactive);

        if self.show_transcript && (self.backend.is_recording() || !self.transcript.is_empty() || !self.turns.is_empty()) {
            self.draw_transcript_strip(ui, t);
            ui.add_space(6.0);
        }

        if !self.status.is_empty() {
            let status = self.status.clone();
            ui.horizontal(|ui| {
                ui.label(RichText::new(&status).size(10.5).color(theme::AMBER));
                if theme::chip(ui, "Dismiss", None).clicked() {
                    self.status.clear();
                }
            });
        }

        // Split what's left into an explicit body rect and a chips rect so
        // the quick-action row is pinned inside the card no matter how tall
        // the transcript strip grew — nested min/max-height hints weren't
        // reliably honored by the scroll areas.
        let avail = ui.available_rect_before_wrap();
        let chips_h = 32.0;
        let body_rect = Rect::from_min_max(avail.min, pos2(avail.max.x, avail.max.y - chips_h - 8.0));
        let chips_rect = Rect::from_min_max(pos2(avail.min.x, avail.max.y - chips_h), avail.max);
        let mut body_ui = ui.new_child(egui::UiBuilder::new().max_rect(body_rect).layout(Layout::top_down(Align::Min)));
        // Hard clip: whatever the scroll areas decide, no pixel of the body
        // may paint into the chips band below it.
        body_ui.set_clip_rect(body_rect.intersect(ui.clip_rect()));
        if self.focus_mode {
            self.draw_live_focus(&mut body_ui, t);
        } else {
            self.draw_conversation(&mut body_ui, t);
        }
        let mut chips_ui = ui.new_child(egui::UiBuilder::new().max_rect(chips_rect).layout(Layout::top_down(Align::Min)));
        chrome_layer(&mut chips_ui, alpha, live, |ui| self.draw_quick_actions(ui));
        ui.allocate_rect(avail, Sense::hover());
    }

    fn switch_audio_source(&mut self, src: AudioSource) {
        self.settings.audio_source = src;
        self.persist();
        if self.backend.is_recording() {
            self.backend.stop_recording();
            self.start_recording(src);
        }
    }

    // ── Transcript strip + history drop-down ────────────────────────────────

    fn draw_transcript_strip(&mut self, ui: &mut egui::Ui, t: f64) {
        egui::Frame::none()
            .fill(theme::PREVIEW)
            .rounding(Rounding::same(8.0))
            .inner_margin(Margin::symmetric(10.0, 7.0))
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.set_min_height(22.0);
                    theme::timer_capsule(ui, t, self.session_secs(), self.backend.is_recording());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        // Hide the strip (bring it back from the ⋯ menu).
                        if theme::icon_button(ui, theme::Icon::Minus, theme::INK2, None, 22.0)
                            .on_hover_text("Hide the transcript — bring it back from the ⋯ menu")
                            .clicked()
                        {
                            self.show_transcript = false;
                        }
                        // Live Focus ↔ full conversation.
                        let focus_icon = if self.focus_mode { theme::Icon::List } else { theme::Icon::Card };
                        if theme::icon_button(ui, focus_icon, theme::INK2, None, 22.0)
                            .on_hover_text(if self.focus_mode { "Show full conversation" } else { "Focus on current answer" })
                            .clicked()
                        {
                            self.focus_mode = !self.focus_mode;
                        }
                        // Transcript-history drop-down.
                        if !self.turns.is_empty() || !self.transcript.is_empty() {
                            let (glyph, active) = if self.transcript_expanded {
                                (theme::Icon::ChevronUp, Some(theme::CONTROL_HOVER))
                            } else {
                                (theme::Icon::ChevronDown, None)
                            };
                            if theme::icon_button(ui, glyph, theme::INK2, active, 22.0)
                                .on_hover_text(if self.transcript_expanded {
                                    "Hide the full transcript"
                                } else {
                                    "Show the full transcript — every question, each with a copy button"
                                })
                                .clicked()
                            {
                                self.transcript_expanded = !self.transcript_expanded;
                            }
                        }
                        if !self.transcript.trim().is_empty() {
                            let key = ui.id().with("strip-copy");
                            let transcript = self.transcript.clone();
                            self.copy_chip(ui, key, &transcript);
                        }
                        ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                            // One line, head-truncated: the newest words stay
                            // visible while the interviewer talks (Mac parity).
                            let (raw, color) = if !self.transcript.is_empty() {
                                (self.transcript.clone(), theme::INK)
                            } else if self.backend.is_recording() {
                                ("Listening… speak anytime.".to_string(), theme::INK3)
                            } else {
                                ("Paused.".to_string(), theme::INK3)
                            };
                            let font = FontId::proportional(12.0);
                            let text = tail_fit(ui, &raw, &font, ui.available_width());
                            ui.label(RichText::new(text).size(12.0).color(color));
                        });
                    });
                });

                if self.transcript_expanded {
                    self.draw_transcript_history(ui);
                }
            });
    }

    /// The expanded transcript: every sent question in order (Q1, Q2, …), each
    /// with its own copy chip, the live partial pinned last, and Copy-all.
    fn draw_transcript_history(&mut self, ui: &mut egui::Ui) {
        ui.add_space(6.0);
        let questions: Vec<(u64, String)> = self.turns.iter().map(|t| (t.id, t.user.clone())).collect();
        let live = self.transcript.trim().to_string();

        ui.horizontal(|ui| {
            ui.label(RichText::new("FULL TRANSCRIPT").size(9.0).color(theme::INK3).strong());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let all = questions
                    .iter()
                    .enumerate()
                    .map(|(i, (_, q))| format!("Q{}: {q}", i + 1))
                    .chain((!live.is_empty()).then(|| format!("LIVE: {live}")))
                    .collect::<Vec<_>>()
                    .join("\n\n");
                if !all.is_empty() {
                    let key = ui.id().with("copy-all");
                    self.copy_chip(ui, key, &all);
                }
            });
        });
        egui::ScrollArea::vertical()
            .id_salt("transcript-history")
            .max_height(200.0)
            .auto_shrink([false, true])
            .stick_to_bottom(true)
            .show(ui, |ui| {
                for (i, (id, q)) in questions.iter().enumerate() {
                    ui.horizontal(|ui| {
                        ui.add_sized(
                            vec2(26.0, 18.0),
                            egui::Label::new(
                                RichText::new(format!("Q{}", i + 1)).size(9.0).color(theme::INK3).monospace(),
                            ),
                        );
                        let key = ui.id().with(("hist-copy", *id));
                        ui.with_layout(Layout::right_to_left(Align::TOP), |ui| {
                            self.copy_chip(ui, key, q);
                            ui.with_layout(Layout::left_to_right(Align::TOP), |ui| {
                                ui.add(egui::Label::new(RichText::new(q).size(11.5).color(theme::INK)).wrap());
                            });
                        });
                    });
                }
                if !live.is_empty() {
                    ui.horizontal(|ui| {
                        ui.add_sized(
                            vec2(26.0, 18.0),
                            egui::Label::new(RichText::new("LIVE").size(8.5).color(theme::RED).monospace()),
                        );
                        ui.add(egui::Label::new(RichText::new(&live).size(11.5).color(theme::INK2)).wrap());
                    });
                }
                if questions.is_empty() && live.is_empty() {
                    ui.label(RichText::new("Nothing captured yet.").size(11.0).color(theme::INK_MUTED));
                }
            });
    }

    // ── Live Focus card ──────────────────────────────────────────────────────

    fn draw_live_focus(&mut self, ui: &mut egui::Ui, t: f64) {
        let total = self.turns.len();
        if total == 0 {
            ui.add_space(26.0);
            ui.vertical_centered(|ui| {
                theme::waveform(ui, t, self.backend.is_recording(), theme::INK3, 34.0);
                ui.label(RichText::new("Waiting for the first question").size(12.5).color(theme::INK2).strong());
                ui.label(
                    RichText::new("The answer appears here the moment the interviewer finishes asking.")
                        .size(10.5)
                        .color(theme::INK_MUTED),
                );
            });
            return;
        }
        let clamped = self.focus_offset.min(total - 1);
        let idx = total - 1 - clamped;
        let is_latest = clamped == 0;
        let (turn_id, question, assistant, streaming, retrying, error, tokens) = {
            let turn = &self.turns[idx];
            (
                turn.id,
                turn.user.clone(),
                turn.assistant.clone(),
                turn.streaming,
                turn.streaming && turn.auto_retried && turn.assistant.is_empty(),
                turn.error,
                turn.input_tokens + turn.output_tokens,
            )
        };

        // Reveal the Copy/Retry/model row while the pointer is over the card.
        let hovering = match self.demo.as_ref() {
            Some(d) => d.force_chrome,
            None => ui.rect_contains_pointer(ui.max_rect()),
        };
        let actions_alpha = ui
            .ctx()
            .animate_bool_with_time(ui.id().with("focus-actions"), hovering && !streaming, theme::HOVER_T);

        // Header: Q badge + question + ‹ n/N › + stop.
        ui.horizontal(|ui| {
            q_badge(ui);
            let font = FontId::proportional(12.0);
            let reserved = if total > 1 { 96.0 } else if streaming { 30.0 } else { 6.0 };
            let text = tail_fit(ui, &question, &font, (ui.available_width() - reserved).max(60.0));
            ui.add(egui::Label::new(RichText::new(text).size(12.0).color(theme::INK2)).truncate())
                .on_hover_text(&question);
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if streaming
                    && theme::icon_button(ui, theme::Icon::Stop, theme::RED, Some(theme::RED.gamma_multiply(0.16)), 20.0)
                        .on_hover_text("Stop generating")
                        .clicked()
                {
                    self.stop_turn(turn_id);
                }
                if total > 1 {
                    if ui.add_enabled(clamped > 0, egui::Button::new("›").small()).on_hover_text("Next question").clicked() {
                        self.focus_offset = clamped.saturating_sub(1);
                    }
                    ui.label(RichText::new(format!("{}/{}", total - clamped, total)).size(9.0).color(theme::INK3).monospace());
                    if ui.add_enabled(clamped < total - 1, egui::Button::new("‹").small()).on_hover_text("Previous question").clicked() {
                        self.focus_offset = (clamped + 1).min(total - 1);
                    }
                }
            });
        });
        ui.separator();

        egui::ScrollArea::vertical()
            .id_salt(("focus", turn_id))
            .auto_shrink([false, false])
            .stick_to_bottom(true)
            .show(ui, |ui| {
                if assistant.is_empty() && streaming {
                    ui.add_space(2.0);
                    ui.horizontal(|ui| {
                        theme::spinner(ui, t, 5.0, theme::INK2);
                        ui.label(
                            RichText::new(if retrying { "Retrying…" } else { "Thinking…" })
                                .size(11.5)
                                .color(theme::INK3),
                        );
                    });
                } else {
                    render_markdown(ui, &assistant, 14.0, if error { theme::AMBER } else { theme::INK });
                    if streaming {
                        stream_caret(ui, t);
                    }
                }
                // Hover-revealed action row (Mac `focusActionRow`) — lives
                // inside the scroll content, right under the answer.
                if actions_alpha > 0.02 && !streaming {
                    ui.add_space(6.0);
                    ui.scope(|ui| {
                        ui.set_opacity(actions_alpha);
                        ui.horizontal(|ui| {
                            let key = ui.id().with(("focus-copy", turn_id));
                            self.copy_chip(ui, key, &assistant);
                            if is_latest {
                                if theme::chip(ui, "Retry", None).on_hover_text("Regenerate this answer").clicked() {
                                    self.retry_turn(turn_id);
                                }
                                let label = format!("{}    ", model_name(&self.settings.selected_model));
                                let resp = ui
                                    .menu_button(RichText::new(label).size(10.5).color(theme::INK2), |ui| {
                                        ui.label(RichText::new("RE-ASK WITH").size(9.0).color(theme::INK3).strong());
                                        egui::ScrollArea::vertical().max_height(280.0).show(ui, |ui| {
                                            let mut picked: Option<String> = None;
                                            let mut last = "";
                                            for m in available_models() {
                                                if m.provider != last {
                                                    ui.add_space(2.0);
                                                    ui.label(RichText::new(m.provider.to_uppercase()).size(9.0).color(theme::INK3).strong());
                                                    last = m.provider;
                                                }
                                                if ui.selectable_label(self.settings.selected_model == m.id, m.name).clicked() {
                                                    picked = Some(m.id.to_string());
                                                    ui.close_menu();
                                                }
                                            }
                                            if let Some(id) = picked {
                                                self.settings.selected_model = id;
                                                self.persist();
                                                self.retry_turn(turn_id);
                                            }
                                        });
                                    })
                                    .response
                                    .on_hover_text("Re-ask the same question with a different model");
                                theme::overlay_chevron(ui.painter(), resp.rect, theme::INK3);
                            }
                            if tokens > 0 {
                                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                    ui.label(RichText::new(format!("{tokens} tokens")).size(9.0).color(theme::INK_MUTED));
                                });
                            }
                        });
                    });
                }
            });
    }

    // ── Full conversation (chat bubbles) ─────────────────────────────────────

    fn draw_conversation(&mut self, ui: &mut egui::Ui, t: f64) {
        let latest_id = self.turns.last().map(|t| t.id);
        let rows: Vec<(u64, String, String, bool, bool, bool)> = self
            .turns
            .iter()
            .map(|turn| {
                (
                    turn.id,
                    turn.user.clone(),
                    turn.assistant.clone(),
                    turn.streaming,
                    turn.error,
                    turn.streaming && turn.auto_retried && turn.assistant.is_empty(),
                )
            })
            .collect();
        egui::ScrollArea::vertical()
            .id_salt("conversation")
            .auto_shrink([false, false])
            .stick_to_bottom(true)
            .show(ui, |ui| {
                for (id, user, assistant, streaming, error, retrying) in rows {
                    ui.add_space(8.0);
                    user_bubble(ui, &user);
                    ui.add_space(6.0);
                    if assistant.is_empty() && streaming {
                        ui.horizontal(|ui| {
                            theme::spinner(ui, t, 5.0, theme::INK2);
                            ui.label(
                                RichText::new(if retrying { "Retrying…" } else { "Thinking…" })
                                    .size(11.5)
                                    .color(theme::INK3),
                            );
                        });
                    } else {
                        render_markdown(ui, &assistant, 14.0, if error { theme::AMBER } else { theme::INK });
                        if streaming {
                            stream_caret(ui, t);
                        } else {
                            ui.add_space(2.0);
                            ui.horizontal(|ui| {
                                let key = ui.id().with(("bubble-copy", id));
                                self.copy_chip(ui, key, &assistant);
                                if latest_id == Some(id)
                                    && theme::chip(ui, "Retry", None).on_hover_text("Regenerate").clicked()
                                {
                                    self.retry_turn(id);
                                }
                            });
                        }
                    }
                    ui.add_space(6.0);
                    ui.separator();
                }
            });
    }

    fn draw_quick_actions(&mut self, ui: &mut egui::Ui) {
        let actions = self.settings.session_mode.quick_actions();
        egui::ScrollArea::horizontal().auto_shrink([false, true]).max_height(30.0).show(ui, |ui| {
            ui.horizontal(|ui| {
                for qa in actions {
                    if theme::chip(ui, qa.label, None).clicked() {
                        let body = if !self.transcript.trim().is_empty() {
                            self.pending_since = None;
                            std::mem::take(&mut self.transcript)
                        } else {
                            std::mem::take(&mut self.input)
                        };
                        self.send_question(format!("{}{}", qa.prompt_prefix, body));
                    }
                }
            });
        });
    }

}

// ── Reusable widgets ─────────────────────────────────────────────────────────

/// A launcher pill: painted icon + label side by side in a capsule. Idle is
/// a charcoal chip; hover lifts it; active flips to the ink (white) fill with
/// inverse content; `attention` tints it amber (missing API key).
fn surface_pill(ui: &mut egui::Ui, icon: IconKind, label: &str, active: bool, attention: bool) -> Response {
    let font = FontId::proportional(12.5);
    // Measured, not laid out: the text color isn't known until the hover /
    // active animation is sampled below, and a galley's color is fixed at
    // layout time (see `theme::text_size`).
    let text_size = ui.fonts(|f| f.layout_no_wrap(label.to_owned(), font.clone(), theme::INK).size());
    let icon_d = 15.0;
    let pad = vec2(14.0, 8.0);
    let size = vec2(
        icon_d + 7.0 + text_size.x + pad.x * 2.0,
        text_size.y.max(icon_d) + pad.y * 2.0,
    );
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = ui.ctx().animate_bool_with_time(resp.id.with("hover"), resp.hovered(), theme::HOVER_T);
    let sel = ui.ctx().animate_bool_with_time(resp.id.with("sel"), active, theme::HOVER_T);

    let mut fill = theme::CONTROL.lerp_to_gamma(theme::CONTROL_HOVER, hov).lerp_to_gamma(theme::INK, sel);
    let stroke = if attention {
        fill = theme::AMBER.gamma_multiply(0.14 + 0.06 * hov);
        Stroke::new(1.0, theme::AMBER.gamma_multiply(0.5))
    } else if active {
        Stroke::new(0.5, theme::STRONG_HAIRLINE)
    } else {
        Stroke::new(0.5, theme::HAIRLINE)
    };
    ui.painter().rect(rect, Rounding::same(rect.height() / 2.0), fill, stroke);

    let fg = if sel > 0.5 {
        theme::INK_INVERSE
    } else if attention {
        theme::AMBER
    } else {
        theme::INK2.lerp_to_gamma(theme::INK, hov)
    };
    let icon_rect = Rect::from_center_size(
        pos2(rect.left() + pad.x + icon_d / 2.0, rect.center().y),
        Vec2::splat(icon_d),
    );
    draw_vicon(ui.painter(), icon_rect, icon, fg, fill);
    ui.painter().text(
        pos2(icon_rect.right() + 7.0, rect.center().y),
        egui::Align2::LEFT_CENTER,
        label,
        font,
        fg,
    );
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Vector icons drawn with the painter (no font/emoji dependency).
fn draw_vicon(painter: &egui::Painter, rect: Rect, kind: IconKind, tint: Color32, bg: Color32) {
    let r = Rounding::same(2.0);
    match kind {
        IconKind::Monitor => {
            let screen = Rect::from_min_max(rect.min, pos2(rect.max.x, rect.min.y + rect.height() * 0.66));
            painter.rect_filled(screen, r, tint);
            // stand + base
            let cx = rect.center().x;
            painter.rect_filled(Rect::from_min_max(pos2(cx - 1.0, screen.max.y), pos2(cx + 1.0, rect.max.y - 2.0)), Rounding::ZERO, tint);
            painter.rect_filled(Rect::from_min_max(pos2(cx - rect.width() * 0.22, rect.max.y - 2.5), pos2(cx + rect.width() * 0.22, rect.max.y)), Rounding::same(1.0), tint);
        }
        IconKind::Document => {
            painter.rect_filled(rect, Rounding::same(2.5), tint);
            // ruled lines in the background color
            for i in 0..3 {
                let y = rect.min.y + rect.height() * (0.32 + i as f32 * 0.22);
                painter.line_segment([pos2(rect.min.x + 3.0, y), pos2(rect.max.x - 3.0, y)], Stroke::new(1.4, bg));
            }
        }
        IconKind::Person => {
            let head_r = rect.width() * 0.22;
            painter.circle_filled(pos2(rect.center().x, rect.min.y + head_r + 1.0), head_r, tint);
            let shoulders = Rect::from_min_max(
                pos2(rect.min.x + 1.0, rect.center().y + 2.0),
                pos2(rect.max.x - 1.0, rect.max.y),
            );
            painter.rect_filled(shoulders, Rounding { nw: head_r, ne: head_r, sw: 1.0, se: 1.0 }, tint);
        }
    }
}

/// Draw hover-revealed chrome: faded to `alpha`, and inert while hidden so a
/// button the user can't see can't be clicked either. The content still
/// allocates its space, so showing and hiding never reflows the layout.
fn chrome_layer(ui: &mut egui::Ui, alpha: f32, interactive: bool, add: impl FnOnce(&mut egui::Ui)) {
    ui.scope(|ui| {
        ui.set_opacity(alpha);
        ui.add_enabled_ui(interactive, add);
    });
}

/// The small "Q" badge on the focus header (inverse text on a grey square).
fn q_badge(ui: &mut egui::Ui) {
    let (rect, _) = ui.allocate_exact_size(vec2(16.0, 16.0), Sense::hover());
    ui.painter().rect_filled(rect, Rounding::same(4.0), theme::INK3);
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        "Q",
        FontId::proportional(10.0),
        theme::INK_INVERSE,
    );
}

/// Right-aligned grey user bubble (the Mac `TurnBubble` user side).
fn user_bubble(ui: &mut egui::Ui, text: &str) {
    let max_w = ui.available_width() * 0.78;
    ui.with_layout(Layout::right_to_left(Align::TOP), |ui| {
        egui::Frame::none()
            .fill(theme::BUBBLE)
            .rounding(Rounding::same(14.0))
            .stroke(Stroke::new(0.5, theme::HAIRLINE))
            .inner_margin(Margin::symmetric(12.0, 8.0))
            .show(ui, |ui| {
                ui.set_max_width(max_w);
                ui.add(egui::Label::new(RichText::new(text).size(12.5).color(theme::INK)).wrap());
            });
    });
}

/// Streaming caret — a painted blinking bar (the `▌` glyph is tofu in some
/// fallback fonts).
pub(crate) fn stream_caret(ui: &mut egui::Ui, t: f64) {
    let (rect, _) = ui.allocate_exact_size(vec2(8.0, 15.0), Sense::hover());
    if (t * 1.6).fract() < 0.55 {
        ui.painter().rect_filled(
            Rect::from_min_size(rect.min + vec2(1.0, 1.5), vec2(5.0, 12.0)),
            Rounding::same(1.5),
            theme::CHATGPT,
        );
    }
}

/// Elide from the FRONT so the tail (the newest words) stays visible — the
/// Mac transcript strip's `.truncationMode(.head)`.
fn tail_fit(ui: &egui::Ui, text: &str, font: &FontId, max_w: f32) -> String {
    let width_of = |c: char| ui.fonts(|f| f.glyph_width(font, c));
    let full: f32 = text.chars().map(width_of).sum();
    if full <= max_w {
        return text.to_owned();
    }
    let mut budget = max_w - width_of('…');
    let mut kept: Vec<char> = Vec::new();
    for c in text.chars().rev() {
        let w = width_of(c);
        if budget < w {
            break;
        }
        budget -= w;
        kept.push(c);
    }
    let mut out = String::from('…');
    out.extend(kept.iter().rev());
    out
}


fn model_name(id: &str) -> String {
    available_models()
        .iter()
        .find(|m| m.id == id)
        .map(|m| m.name.to_string())
        .unwrap_or_else(|| id.to_string())
}


/// Fixed-width, left-aligned form label + a comfortably padded field. The
/// label cell is allocated at exactly `label_w` so every field in a section
/// starts on the same column.
fn form_row(ui: &mut egui::Ui, label: &str, label_w: f32, add_field: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(vec2(label_w, 26.0), Sense::hover());
        let mut cell = ui.new_child(egui::UiBuilder::new().max_rect(rect).layout(Layout::left_to_right(Align::Center)));
        cell.label(RichText::new(label).size(12.0).color(theme::INK2));
        add_field(ui);
    });
}

pub(crate) fn labeled(ui: &mut egui::Ui, label: &str, value: &mut String) {
    form_row(ui, label, 86.0, |ui| {
        ui.add(
            egui::TextEdit::singleline(value)
                .desired_width(f32::INFINITY)
                .margin(Margin::symmetric(10.0, 6.0)),
        );
    });
}

pub(crate) fn key_field(ui: &mut egui::Ui, label: &str, value: &mut String) {
    form_row(ui, label, 120.0, |ui| {
        ui.add(
            egui::TextEdit::singleline(value)
                .password(true)
                .desired_width(f32::INFINITY)
                .margin(Margin::symmetric(10.0, 6.0))
                .hint_text("paste key"),
        );
    });
}

/// Scene names for the THECLOSER_DEMO gallery, in step order.
const DEMO_SCENES: [&str; 15] = [
    "01-bar",
    "02-pill",
    "03-setup",
    "04-setup-scrolled",
    // The demo never has a cursor over the window, so this captures the
    // resting immersive state: question + answer, no chrome.
    "05-live-focus",
    // Same moment with the chrome revealed, as if the cursor were inside.
    "05b-live-focus-hover",
    "06-transcript-history",
    "07-conversation",
    "08-resume-build",
    "09-resume-scored",
    "10-resume-generations",
    "11-profile-ai",
    "12-profile-prompts",
    "13-profile-panel",
    // Closing a surface must leave the bar exactly where it was — check the
    // [geo] trace: this scene's bottom edge should match scene 01's.
    "14-bar-again",
];

fn save_png(path: &std::path::Path, img: &egui::ColorImage) {
    let [w, h] = img.size;
    let mut buf = Vec::with_capacity(w * h * 4);
    for px in &img.pixels {
        buf.extend_from_slice(&px.to_srgba_unmultiplied());
    }
    let _ = image::save_buffer(path, &buf, w as u32, h as u32, image::ColorType::Rgba8);
}

/// Errors worth one silent retry: rate limits, provider overloads, gateway
/// hiccups, dropped sockets. Auth/key errors are NOT here on purpose — they
/// will fail identically and the user needs to see them.
fn is_transient_error(msg: &str) -> bool {
    let m = msg.to_ascii_lowercase();
    ["429", "500", "502", "503", "529", "overloaded", "rate limit", "timeout", "timed out", "connection", "network", "temporar"]
        .iter()
        .any(|k| m.contains(k))
}

/// Minimal Markdown: headings, `-`/`*` bullets, `1.` numbered lists,
/// **bold**, `inline code`.
pub(crate) fn render_markdown(ui: &mut egui::Ui, text: &str, size: f32, base: Color32) {
    let max_width = ui.available_width();
    for line in text.split('\n') {
        if line.trim().is_empty() {
            ui.add_space(size * 0.35);
            continue;
        }
        let (content, level) = if let Some(r) = line.strip_prefix("### ") {
            (r, 3)
        } else if let Some(r) = line.strip_prefix("## ") {
            (r, 2)
        } else if let Some(r) = line.strip_prefix("# ") {
            (r, 1)
        } else {
            (line, 0)
        };
        let (bullet, content) = match content.strip_prefix("- ").or_else(|| content.strip_prefix("* ")) {
            Some(r) => (true, r),
            None => (false, content),
        };
        let number = if !bullet { leading_number(content) } else { None };
        let fsize = match level {
            1 => size + 5.0,
            2 => size + 3.0,
            3 => size + 1.0,
            _ => size,
        };
        let mut job = LayoutJob::default();
        job.wrap.max_width = max_width;
        if bullet {
            job.append("•  ", 0.0, fmt(fsize, theme::CHATGPT));
        }
        if let Some((num, rest)) = number {
            job.append(&format!("{num}  "), 0.0, fmt(fsize, theme::CHATGPT));
            append_inline(&mut job, rest, fsize, base, level > 0);
        } else {
            append_inline(&mut job, content, fsize, base, level > 0);
        }
        ui.label(job);
    }
}

/// `"1. text"` → `Some(("1.", "text"))`, used to tint list numbers like bullets.
fn leading_number(line: &str) -> Option<(&str, &str)> {
    let dot = line.find(". ")?;
    if dot == 0 || dot > 2 || !line[..dot].bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some((&line[..=dot], line[dot + 2..].trim_start()))
}

fn append_inline(job: &mut LayoutJob, text: &str, size: f32, base: Color32, force_strong: bool) {
    let mut code_mode = false;
    for code_seg in text.split('`') {
        if code_mode {
            let mut f = fmt(size * 0.95, Color32::from_rgb(210, 220, 200));
            f.font_id = FontId::monospace(size * 0.95);
            f.background = theme::CODE;
            job.append(code_seg, 0.0, f);
        } else {
            let mut bold = false;
            for seg in code_seg.split("**") {
                if !seg.is_empty() {
                    let strong = bold || force_strong;
                    job.append(seg, 0.0, fmt(size, if strong { Color32::WHITE } else { base }));
                }
                bold = !bold;
            }
        }
        code_mode = !code_mode;
    }
}

fn fmt(size: f32, color: Color32) -> TextFormat {
    TextFormat { font_id: FontId::proportional(size), color, ..Default::default() }
}
