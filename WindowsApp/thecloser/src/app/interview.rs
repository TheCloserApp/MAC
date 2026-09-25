//! The Interview surface's setup form and the live session's ⋯ menu.
//!
//! Ports `InterviewSetupForm` (mode tabs, session profile, résumé picker with
//! upload, attached context files, system-prompt preset picker, auto-generate
//! toggle, missing-key banner, Start) and the macOS top-strip overflow menu
//! (transparency, background, transcription engine, transcript + focus
//! toggles, token counts, reset position, quit).

use egui::{vec2, Align, Layout, Margin, RichText, Rounding, Sense, Stroke, ViewportCommand};

use copilot_core::prompts::PromptKind;
use copilot_core::settings::{AudioSource, SttProvider};
use copilot_core::SessionMode;

use super::{App, PromptDraft, Surface};
use crate::theme;

impl App {
    // ── Setup form ──────────────────────────────────────────────────────────

    pub(super) fn draw_interview_setup(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.add_space(4.0);
            ui.label(RichText::new("Set up your interview").size(18.0).color(theme::INK).strong());
            ui.label(
                RichText::new("Pick a mode, attach your résumé and context, choose a prompt, then hit Start.")
                    .size(11.5)
                    .color(theme::INK3),
            );
            ui.add_space(14.0);

            self.setup_mode_section(ui);
            ui.add_space(14.0);
            self.setup_resume_section(ui);
            ui.add_space(14.0);
            self.setup_context_section(ui);
            ui.add_space(14.0);
            self.setup_prompt_section(ui);
            ui.add_space(14.0);
            self.setup_profile_section(ui);
            ui.add_space(14.0);
            self.setup_model_section(ui);
            ui.add_space(16.0);
            self.setup_start_row(ui, ctx);
            ui.add_space(6.0);
        });

        self.draw_prompt_sheet(ctx);
    }

    fn setup_mode_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Mode", false);
        ui.horizontal_wrapped(|ui| {
            for mode in SessionMode::ALL {
                let sel = self.settings.session_mode == mode;
                if theme::segment_pill(ui, mode.display_name(), sel).clicked() {
                    self.settings.session_mode = mode;
                    // Picking a mode activates the prompt the user linked to
                    // it, matching the Mac mode menu.
                    let linked = self.prompts.linked(mode).map(|p| p.id);
                    self.prompts.set_active(PromptKind::Conversation, linked);
                    self.persist();
                }
            }
        });
    }

    /// Résumé card: pick a saved résumé, upload a new one, or clear it.
    fn setup_resume_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Résumé", true);
        ui.label(
            RichText::new("Answers get grounded in this — your real projects, employers, and stack.")
                .size(11.0)
                .color(theme::INK3),
        );
        ui.add_space(4.0);
        ui.horizontal_wrapped(|ui| {
            let label = match self.resumes.active() {
                Some(p) => format!("{}    ", ellipsize(&p.name, 28)),
                None => "No résumé selected    ".to_string(),
            };
            let resp = ui
                .menu_button(RichText::new(label).size(11.5).color(theme::INK2), |ui| {
                    ui.set_min_width(200.0);
                    if self.resumes.presets.is_empty() {
                        ui.label(RichText::new("No saved résumés yet").size(11.0).color(theme::INK3));
                    }
                    let mut pick = None;
                    for p in &self.resumes.presets {
                        if ui.selectable_label(self.resumes.active_id == Some(p.id), &p.name).clicked() {
                            pick = Some(p.id);
                            ui.close_menu();
                        }
                    }
                    if let Some(id) = pick {
                        self.resumes.active_id = Some(id);
                    }
                    if self.resumes.active_id.is_some() {
                        ui.separator();
                        if ui.button("Use no résumé").clicked() {
                            self.resumes.active_id = None;
                            ui.close_menu();
                        }
                    }
                })
                .response;
            theme::overlay_chevron(ui.painter(), resp.rect, theme::INK3);

            if theme::chip(ui, "Upload…", None)
                .on_hover_text("PDF · DOCX · RTF · TXT · MD")
                .clicked()
            {
                if let Some(path) = Self::pick_files(false).first() {
                    self.import_resume(path);
                }
            }

            if let Some(p) = self.resumes.active() {
                let words = p.content.split_whitespace().count();
                ui.label(RichText::new(format!("{words} words")).size(10.0).color(theme::INK_MUTED));
            }
        });
    }

    /// Free-text context plus attached files, shown as removable chips.
    fn setup_context_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Context", true);
        ui.label(
            RichText::new("Job description, notes, talking points.")
                .size(11.0)
                .color(theme::INK3),
        );
        ui.add(
            egui::TextEdit::multiline(&mut self.settings.context)
                .desired_rows(4)
                .desired_width(f32::INFINITY)
                .margin(Margin::symmetric(10.0, 8.0))
                .hint_text("Role, company, JD, talking points…"),
        );
        ui.add_space(6.0);
        ui.horizontal_wrapped(|ui| {
            let label = if self.attachments.is_empty() { "Attach files…" } else { "Attach more…" };
            if theme::chip(ui, label, None)
                .on_hover_text("PDF · DOCX · RTF · TXT · MD — text is extracted and sent as context")
                .clicked()
            {
                let paths = Self::pick_files(true);
                self.import_attachments(&paths);
            }
            let mut remove = None;
            for (i, a) in self.attachments.iter().enumerate() {
                if file_chip(ui, &a.name).clicked() {
                    remove = Some(i);
                }
            }
            if let Some(i) = remove {
                self.attachments.remove(i);
            }
        });
    }

    /// System-prompt preset picker + create/edit, the Mac "System prompt" card.
    fn setup_prompt_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "System prompt", false);
        ui.horizontal_wrapped(|ui| {
            let active = self.prompts.active(PromptKind::Conversation);
            let label = match active {
                Some(p) => format!("{}    ", ellipsize(&p.name, 26)),
                None => format!("Default ({})    ", self.settings.session_mode.display_name()),
            };
            let resp = ui
                .menu_button(RichText::new(label).size(11.5).color(theme::INK2), |ui| {
                    ui.set_min_width(220.0);
                    let is_default = self.prompts.active(PromptKind::Conversation).is_none();
                    if ui
                        .selectable_label(
                            is_default,
                            format!("Default ({})", self.settings.session_mode.display_name()),
                        )
                        .clicked()
                    {
                        self.prompts.set_active(PromptKind::Conversation, None);
                        ui.close_menu();
                    }
                    ui.separator();
                    let mut pick = None;
                    for p in self.prompts.of_kind(PromptKind::Conversation) {
                        let sel = self.prompts.active_id == Some(p.id);
                        if ui.selectable_label(sel, &p.name).clicked() {
                            pick = Some(p.id);
                        }
                    }
                    if let Some(id) = pick {
                        self.prompts.set_active(PromptKind::Conversation, Some(id));
                        ui.close_menu();
                    }
                })
                .response;
            theme::overlay_chevron(ui.painter(), resp.rect, theme::INK3);

            if theme::chip(ui, "New…", None).on_hover_text("Save a new system prompt").clicked() {
                self.prompt_draft = Some(PromptDraft {
                    editing: None,
                    name: String::new(),
                    content: String::new(),
                    kind: PromptKind::Conversation,
                });
            }
            if let Some(p) = self.prompts.active(PromptKind::Conversation) {
                let (id, name, content) = (p.id, p.name.clone(), p.content.clone());
                if theme::chip(ui, "Edit…", None).clicked() {
                    self.prompt_draft = Some(PromptDraft {
                        editing: Some(id),
                        name,
                        content,
                        kind: PromptKind::Conversation,
                    });
                }
            }
        });
    }

    fn setup_profile_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "You", true);
        super::labeled(ui, "Name", &mut self.settings.user_name);
        super::labeled(ui, "Role", &mut self.settings.user_role);
        super::labeled(ui, "Company", &mut self.settings.user_company);
    }

    fn setup_model_section(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Model & audio", false);
        ui.horizontal_wrapped(|ui| {
            self.model_picker(ui);
            ui.add_space(8.0);
            for src in [AudioSource::System, AudioSource::Microphone] {
                if theme::segment_pill(ui, src.label(), self.settings.audio_source == src).clicked() {
                    self.settings.audio_source = src;
                    self.persist();
                }
            }
        });
        ui.add_space(6.0);
        if ui
            .checkbox(&mut self.settings.auto_generate, "Auto-generate answers as questions arrive")
            .on_hover_text("Off: the transcript still runs, but nothing is sent until you press Send.")
            .changed()
        {
            self.persist();
        }
    }

    fn setup_start_row(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        if self.settings.provider_keys_missing() {
            if theme::warning_banner(
                ui,
                "No API key for the selected model — answers won't generate. Click to add one.",
            )
            .clicked()
            {
                self.set_surface(ctx, Some(Surface::Profile));
            }
            ui.add_space(8.0);
            return;
        }
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            if theme::primary_capsule(ui, "Start interview").clicked() {
                self.persist();
                self.start_interview(ctx);
            }
            ui.label(
                RichText::new("Listens to the interviewer and answers as they pause.")
                    .size(10.0)
                    .color(theme::INK_MUTED),
            );
        });
    }

    // ── New / edit prompt sheet ─────────────────────────────────────────────

    /// Modal editor for a saved system prompt (the Mac `createPromptSheet`).
    pub(super) fn draw_prompt_sheet(&mut self, ctx: &egui::Context) {
        let Some(draft) = self.prompt_draft.as_mut() else { return };
        let mut open = true;
        let mut save = false;
        let mut delete = false;
        let title = if draft.editing.is_some() { "Edit system prompt" } else { "New system prompt" };

        egui::Window::new(title)
            .collapsible(false)
            .resizable(true)
            .default_width(430.0)
            .anchor(egui::Align2::CENTER_CENTER, vec2(0.0, 0.0))
            .open(&mut open)
            .show(ctx, |ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut draft.name)
                        .hint_text("Name")
                        .desired_width(f32::INFINITY)
                        .margin(Margin::symmetric(10.0, 6.0)),
                );
                ui.add_space(6.0);
                ui.label(RichText::new("Prompt").size(11.0).color(theme::INK3));
                ui.add(
                    egui::TextEdit::multiline(&mut draft.content)
                        .desired_rows(10)
                        .desired_width(f32::INFINITY)
                        .margin(Margin::symmetric(10.0, 8.0))
                        .hint_text("You are…  ({NAME}, {ROLE}, {COMPANY} are substituted)"),
                );
                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    ui.label(RichText::new("Used for").size(11.0).color(theme::INK3));
                    for kind in PromptKind::ALL {
                        if theme::segment_pill(ui, kind.display_name(), draft.kind == kind).clicked() {
                            draft.kind = kind;
                        }
                    }
                });
                ui.add_space(10.0);
                ui.horizontal(|ui| {
                    let ready = !draft.name.trim().is_empty() && !draft.content.trim().is_empty();
                    if ready && theme::primary_capsule(ui, "Save").clicked() {
                        save = true;
                    }
                    if !ready {
                        ui.label(RichText::new("Name and prompt are required.").size(10.5).color(theme::INK_MUTED));
                    }
                    if draft.editing.is_some() {
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if theme::chip(ui, "Delete", Some(theme::RED)).clicked() {
                                delete = true;
                            }
                        });
                    }
                });
            });

        if save {
            let draft = self.prompt_draft.take().expect("checked above");
            match draft.editing {
                Some(id) => self.prompts.update(id, &draft.name, &draft.content),
                None => {
                    let id = self.prompts.add(&draft.name, &draft.content, draft.kind);
                    // Activate what you just wrote — that's why you wrote it.
                    self.prompts.set_active(draft.kind, Some(id));
                }
            }
            self.status = "Prompt saved.".into();
        } else if delete {
            let draft = self.prompt_draft.take().expect("checked above");
            if let Some(id) = draft.editing {
                self.prompts.delete(id);
            }
        } else if !open {
            self.prompt_draft = None;
        }
    }

    // ── Live session ⋯ menu ─────────────────────────────────────────────────

    /// Full parity with the macOS top-strip overflow menu.
    pub(super) fn session_menu(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        ui.set_min_width(232.0);

        if ui.button("New session").clicked() {
            self.end_session();
            ui.close_menu();
        }
        let rec = self.backend.is_recording();
        if ui.button(if rec { "Pause listening" } else { "Resume listening" }).clicked() {
            if rec {
                self.stop_recording();
            } else {
                self.start_recording(self.settings.audio_source);
            }
            ui.close_menu();
        }

        ui.separator();
        ui.label(RichText::new("AUDIO SOURCE").size(9.0).color(theme::INK3).strong());
        for src in [AudioSource::System, AudioSource::Microphone] {
            if ui.selectable_label(self.settings.audio_source == src, src.label()).clicked() {
                self.switch_audio_source(src);
                ui.close_menu();
            }
        }

        ui.separator();
        ui.menu_button(
            format!("Transparency: {}%", (self.settings.opacity * 100.0).round() as i32),
            |ui| {
                for level in [1.0_f32, 0.85, 0.7, 0.55, 0.4] {
                    let sel = (self.settings.opacity - level).abs() < 0.01;
                    if ui.selectable_label(sel, format!("{}%", (level * 100.0) as i32)).clicked() {
                        self.settings.opacity = level;
                        self.persist();
                        ui.close_menu();
                    }
                }
            },
        );
        ui.menu_button(
            format!("Background: {}%", (self.settings.background_opacity * 100.0).round() as i32),
            |ui| {
                for level in [1.0_f32, 0.8, 0.6, 0.4, 0.2] {
                    let sel = (self.settings.background_opacity - level).abs() < 0.01;
                    if ui.selectable_label(sel, format!("{}%", (level * 100.0) as i32)).clicked() {
                        self.settings.background_opacity = level;
                        self.persist();
                        ui.close_menu();
                    }
                }
            },
        );
        ui.menu_button(format!("Transcription: {}", self.settings.stt_provider.label()), |ui| {
            for p in [SttProvider::OpenAi, SttProvider::ElevenLabs] {
                if ui.selectable_label(self.settings.stt_provider == p, p.label()).clicked() {
                    self.settings.stt_provider = p;
                    self.persist();
                    // The engine is snapshotted when capture starts, so restart
                    // to make the switch take effect mid-session.
                    if self.backend.is_recording() {
                        self.backend.stop_recording();
                        self.start_recording(self.settings.audio_source);
                    }
                    ui.close_menu();
                }
            }
        });

        ui.separator();
        if ui.selectable_label(self.show_transcript, "Show live transcript").clicked() {
            self.show_transcript = !self.show_transcript;
            ui.close_menu();
        }
        if ui.selectable_label(self.focus_mode, "Focus mode (current Q&A only)").clicked() {
            self.focus_mode = !self.focus_mode;
            ui.close_menu();
        }
        if ui.checkbox(&mut self.settings.auto_send, "Auto-send on pause").changed() {
            self.persist();
        }
        if ui.checkbox(&mut self.settings.auto_generate, "Auto-generate answers").changed() {
            self.persist();
        }
        if ui.checkbox(&mut self.settings.show_token_counts, "Show token counts").changed() {
            self.persist();
        }

        if self.settings.show_token_counts {
            ui.separator();
            let (input, output): (u32, u32) =
                self.turns.iter().fold((0, 0), |(i, o), t| (i + t.input_tokens, o + t.output_tokens));
            ui.label(
                RichText::new(format!("{input} in · {output} out · {} total", input + output))
                    .size(10.0)
                    .color(theme::INK3),
            );
        }

        ui.separator();
        if ui.button("Reset overlay position").clicked() {
            self.settings.panel_x = 80.0;
            self.settings.panel_y = 60.0;
            ctx.send_viewport_cmd(ViewportCommand::OuterPosition(egui::pos2(80.0, 60.0)));
            self.persist();
            ui.close_menu();
        }
        if ui.button("Quit thecloser").clicked() {
            self.persist();
            ctx.send_viewport_cmd(ViewportCommand::Close);
        }
    }
}

/// A removable attachment chip: filename plus an × hit-target.
fn file_chip(ui: &mut egui::Ui, name: &str) -> egui::Response {
    let font = egui::FontId::proportional(11.0);
    let label = ellipsize(name, 26);
    let text_w = ui.fonts(|f| f.layout_no_wrap(label.clone(), font.clone(), theme::INK).size().x);
    let pad = vec2(10.0, 5.0);
    let size = vec2(text_w + 16.0 + pad.x * 2.0, 22.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = ui.ctx().animate_bool_with_time(resp.id.with("h"), resp.hovered(), theme::HOVER_T);
    let p = ui.painter();
    p.rect(
        rect,
        Rounding::same(7.0),
        theme::CONTROL.lerp_to_gamma(theme::CONTROL_HOVER, hov),
        Stroke::new(0.5, theme::HAIRLINE),
    );
    p.text(
        egui::pos2(rect.left() + pad.x, rect.center().y),
        egui::Align2::LEFT_CENTER,
        &label,
        font,
        theme::INK,
    );
    // The × mark — the whole chip is the hit target, which is easier to hit
    // than a 10px glyph mid-interview.
    let c = egui::pos2(rect.right() - 11.0, rect.center().y);
    let r = 3.2;
    let s = Stroke::new(1.3, theme::INK3.lerp_to_gamma(theme::INK, hov));
    p.line_segment([egui::pos2(c.x - r, c.y - r), egui::pos2(c.x + r, c.y + r)], s);
    p.line_segment([egui::pos2(c.x + r, c.y - r), egui::pos2(c.x - r, c.y + r)], s);
    resp.on_hover_text(format!("Remove {name}"))
}

/// Middle-truncate so both the name and its extension stay readable.
pub(super) fn ellipsize(s: &str, max: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max {
        return s.to_string();
    }
    let head: String = chars[..max.saturating_sub(9)].iter().collect();
    let tail: String = chars[chars.len() - 6..].iter().collect();
    format!("{head}…{tail}")
}

#[cfg(test)]
mod tests {
    use super::ellipsize;

    #[test]
    fn keeps_short_names_intact() {
        assert_eq!(ellipsize("resume.pdf", 26), "resume.pdf");
    }

    #[test]
    fn middle_truncates_long_names_keeping_the_extension() {
        let out = ellipsize("a-very-long-resume-filename-2026-final.docx", 26);
        assert!(out.ends_with(".docx"), "extension must survive: {out}");
        assert!(out.contains('…'));
        assert!(out.chars().count() <= 26);
    }
}
