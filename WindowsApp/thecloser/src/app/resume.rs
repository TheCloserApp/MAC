//! The Résumé surface — a port of the macOS `ResumePanelView`.
//!
//! Two tabs. **Build** holds the résumé library (pick / upload / rename /
//! edit / delete), the job description, the ATS score card, and the tailored
//! output. **Generations** is the run history: every tailoring keeps its
//! inputs and its before/after scores, so the list shows a real score delta
//! and any past output can be reopened, copied, or saved.

use egui::{vec2, Align, Layout, Margin, RichText, Rounding, Sense, Stroke};

use copilot_core::resumes::{ResumeScore, ScoreBand};

use super::{render_markdown, stream_caret, App, ResumeTab};
use crate::theme;

impl App {
    pub(super) fn draw_resume(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Résumé").size(15.0).color(theme::INK).strong());
            ui.label(
                RichText::new("Tailor a résumé to any job description")
                    .size(11.0)
                    .color(theme::INK3),
            );
        });
        ui.add_space(8.0);

        // Tab bar.
        ui.horizontal(|ui| {
            let count = self.resumes.generations.len();
            if theme::segment_pill(ui, "Build", self.resume_tab == ResumeTab::Build).clicked() {
                self.resume_tab = ResumeTab::Build;
            }
            let label =
                if count > 0 { format!("Generations ({count})") } else { "Generations".to_string() };
            if theme::segment_pill(ui, &label, self.resume_tab == ResumeTab::Generations).clicked() {
                self.resume_tab = ResumeTab::Generations;
                self.open_generation = None;
            }
        });
        ui.add_space(4.0);
        ui.separator();

        match self.resume_tab {
            ResumeTab::Build => self.draw_resume_build(ui),
            ResumeTab::Generations => self.draw_resume_history(ui),
        }
    }

    // ── Build tab ───────────────────────────────────────────────────────────

    fn draw_resume_build(&mut self, ui: &mut egui::Ui) {
        let mut area = egui::ScrollArea::vertical().id_salt("resume-build").auto_shrink([false, false]);
        if let Some(offset) = self.demo_scroll() {
            area = area.vertical_scroll_offset(offset);
        }
        area.show(ui, |ui| {
            ui.add_space(6.0);
            self.resume_card(ui);
            ui.add_space(14.0);
            self.jd_card(ui);
            ui.add_space(12.0);
            self.generate_row(ui);
            ui.add_space(10.0);
            self.score_card(ui);
            self.output_card(ui);
            ui.add_space(6.0);
        });
    }

    /// Library picker + upload/new/rename/delete, then either the library
    /// list or the active résumé's editable body.
    fn resume_card(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Résumé", false);
        ui.horizontal_wrapped(|ui| {
            let label = match self.resumes.active() {
                Some(p) => format!("{}    ", super::interview::ellipsize(&p.name, 26)),
                None => "No résumé yet    ".to_string(),
            };
            let resp = ui
                .menu_button(RichText::new(label).size(11.5).color(theme::INK2), |ui| {
                    ui.set_min_width(220.0);
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
                        self.show_resume_library = false;
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
            if theme::chip(ui, "New", None).on_hover_text("Start an empty résumé").clicked() {
                self.resumes.add("Untitled résumé", "", None);
                self.show_resume_library = false;
            }
            let label = if self.show_resume_library { "Hide library" } else { "Library" };
            if theme::chip(ui, label, None).clicked() {
                self.show_resume_library = !self.show_resume_library;
            }
        });

        ui.add_space(6.0);
        if self.show_resume_library {
            self.resume_library_list(ui);
        } else {
            self.resume_editor(ui);
        }
    }

    fn resume_library_list(&mut self, ui: &mut egui::Ui) {
        if self.resumes.presets.is_empty() {
            ui.label(
                RichText::new("Upload a résumé to get started.").size(11.0).color(theme::INK_MUTED),
            );
            return;
        }
        let rows: Vec<(u64, String, usize)> = self
            .resumes
            .presets
            .iter()
            .map(|p| (p.id, p.name.clone(), p.content.split_whitespace().count()))
            .collect();
        let mut delete = None;
        for (id, name, words) in rows {
            let active = self.resumes.active_id == Some(id);
            egui::Frame::none()
                .fill(if active { theme::CONTROL } else { theme::PREVIEW })
                .rounding(Rounding::same(8.0))
                .stroke(Stroke::new(0.5, if active { theme::STRONG_HAIRLINE } else { theme::HAIRLINE }))
                .inner_margin(Margin::symmetric(10.0, 7.0))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        if ui
                            .add(egui::Label::new(RichText::new(&name).size(12.0).color(theme::INK)).sense(Sense::click()))
                            .on_hover_text("Use this résumé")
                            .clicked()
                        {
                            self.resumes.active_id = Some(id);
                        }
                        ui.label(RichText::new(format!("{words} words")).size(10.0).color(theme::INK_MUTED));
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if theme::chip(ui, "Delete", None).clicked() {
                                delete = Some(id);
                            }
                        });
                    });
                });
            ui.add_space(4.0);
        }
        if let Some(id) = delete {
            self.resumes.delete(id);
        }
    }

    /// Editable body of the active résumé, saved back to the library on change.
    fn resume_editor(&mut self, ui: &mut egui::Ui) {
        let Some(active) = self.resumes.active().cloned() else {
            ui.label(
                RichText::new("Upload a résumé, or hit New to type one in.")
                    .size(11.0)
                    .color(theme::INK_MUTED),
            );
            return;
        };
        let mut name = active.name.clone();
        ui.horizontal(|ui| {
            ui.label(RichText::new("Name").size(11.0).color(theme::INK3));
            if ui
                .add(
                    egui::TextEdit::singleline(&mut name)
                        .desired_width(f32::INFINITY)
                        .margin(Margin::symmetric(8.0, 5.0)),
                )
                .changed()
            {
                self.resumes.rename(active.id, &name);
            }
        });
        ui.add_space(4.0);
        let mut content = active.content.clone();
        if ui
            .add(
                egui::TextEdit::multiline(&mut content)
                    .desired_rows(7)
                    .desired_width(f32::INFINITY)
                    .margin(Margin::symmetric(10.0, 8.0))
                    .hint_text("Paste your résumé text…"),
            )
            .changed()
        {
            self.resumes.update_content(active.id, &content);
        }
    }

    fn jd_card(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Job description", true);
        ui.add(
            egui::TextEdit::multiline(&mut self.jd_text)
                .desired_rows(5)
                .desired_width(f32::INFINITY)
                .margin(Margin::symmetric(10.0, 8.0))
                .hint_text("Paste the job description…"),
        );
        ui.add_space(6.0);
        ui.horizontal_wrapped(|ui| {
            if theme::chip(ui, "Attach a JD file…", None).clicked() {
                if let Some(path) = Self::pick_files(false).first() {
                    match copilot_core::files::import(path) {
                        Ok(imported) => self.jd_text = imported.text,
                        Err(e) => self.status = format!("{e}"),
                    }
                }
            }
            if !self.jd_text.is_empty() && theme::chip(ui, "Clear", None).clicked() {
                self.jd_text.clear();
            }
        });
    }

    fn generate_row(&mut self, ui: &mut egui::Ui) {
        let busy = self.active_generation.is_some();
        ui.horizontal_wrapped(|ui| {
            let label = if busy { "Tailoring…" } else { "Tailor résumé" };
            if theme::primary_capsule(ui, label).clicked() && !busy {
                self.tailor_resume();
            }
            let scoring = self.scoring.is_some();
            let score_label = if scoring { "Scoring…" } else { "Score against JD" };
            if theme::chip(ui, score_label, None)
                .on_hover_text("ATS-style match score, without rewriting anything")
                .clicked()
                && !scoring
            {
                self.score_only();
            }
            self.model_picker(ui);
        });
        if self.settings.provider_keys_missing() {
            ui.add_space(6.0);
            theme::warning_banner(ui, "No API key for the selected model — add one in Profile.");
        }
    }

    /// Before / after score for the generation currently in view.
    fn score_card(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.current_generation() else { return };
        let Some(g) = self.resumes.generation(id) else { return };
        let (before, after) = (g.before_score.clone(), g.after_score.clone());
        if before.is_none() && after.is_none() && self.scoring.is_none() {
            return;
        }
        theme::section_header(ui, "Match score", false);
        egui::Frame::none()
            .fill(theme::PREVIEW)
            .rounding(Rounding::same(8.0))
            .inner_margin(Margin::same(12.0))
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    match (&before, &after) {
                        (Some(b), Some(a)) => {
                            score_dial(ui, b.score, "Before");
                            ui.add_space(6.0);
                            delta_chip(ui, a.score - b.score);
                            ui.add_space(6.0);
                            score_dial(ui, a.score, "After");
                        }
                        (Some(b), None) => score_dial(ui, b.score, "Current"),
                        (None, Some(a)) => score_dial(ui, a.score, "Tailored"),
                        (None, None) => {}
                    }
                    if self.scoring.is_some() {
                        ui.add_space(8.0);
                        theme::spinner(ui, ui.input(|i| i.time), 5.0, theme::INK2);
                        ui.label(RichText::new("Scoring…").size(11.0).color(theme::INK3));
                    }
                });
                let shown = after.as_ref().or(before.as_ref());
                if let Some(s) = shown {
                    if !s.verdict.is_empty() {
                        ui.add_space(6.0);
                        ui.label(RichText::new(&s.verdict).size(11.5).color(theme::INK2));
                    }
                    ui.label(RichText::new(s.recommendation()).size(10.5).color(theme::INK_MUTED));
                    if !s.strengths.is_empty() {
                        ui.add_space(6.0);
                        keyword_row(ui, "Strengths", &s.strengths, theme::GREEN);
                    }
                    if !s.missing.is_empty() {
                        keyword_row(ui, "Missing", &s.missing, theme::AMBER);
                    }
                }
            });
        ui.add_space(12.0);
    }

    fn output_card(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.current_generation() else { return };
        let Some(g) = self.resumes.generation(id) else { return };
        let text = g.generated_text.clone();
        if text.is_empty() {
            return;
        }
        let streaming = self.active_generation == Some(id);
        theme::section_header(ui, "Tailored résumé", false);
        ui.horizontal_wrapped(|ui| {
            let key = ui.id().with(("gen-copy", id));
            self.copy_chip(ui, key, &text);
            if theme::chip(ui, "Save as…", None).clicked() {
                let name = self
                    .resumes
                    .active()
                    .map(|p| format!("{}-tailored.md", p.name.replace(' ', "-")))
                    .unwrap_or_else(|| "tailored-resume.md".into());
                self.save_text_as(&name, &text);
            }
            if !streaming && theme::chip(ui, "Use as my résumé", None)
                .on_hover_text("Save the tailored text as a new résumé in the library")
                .clicked()
            {
                let base = self.resumes.active().map(|p| p.name.clone()).unwrap_or_else(|| "Résumé".into());
                self.resumes.add(&format!("{base} (tailored)"), &text, None);
                self.status = "Saved as a new résumé.".into();
            }
        });
        ui.add_space(6.0);
        egui::Frame::none()
            .fill(theme::PREVIEW)
            .rounding(Rounding::same(8.0))
            .inner_margin(Margin::same(12.0))
            .show(ui, |ui| {
                render_markdown(ui, &text, 13.0, theme::INK);
                if streaming {
                    stream_caret(ui, ui.input(|i| i.time));
                }
            });
    }

    // ── Generations tab ─────────────────────────────────────────────────────

    fn draw_resume_history(&mut self, ui: &mut egui::Ui) {
        if let Some(id) = self.open_generation {
            if self.resumes.generation(id).is_some() {
                self.draw_generation_detail(ui, id);
                return;
            }
            self.open_generation = None;
        }

        if self.resumes.generations.is_empty() {
            ui.add_space(28.0);
            ui.vertical_centered(|ui| {
                ui.label(RichText::new("No generations yet").size(12.5).color(theme::INK2).strong());
                ui.label(
                    RichText::new("Tailor a résumé on the Build tab and every run lands here, with its score.")
                        .size(10.5)
                        .color(theme::INK_MUTED),
                );
            });
            return;
        }

        ui.horizontal(|ui| {
            let n = self.resumes.generations.len();
            ui.label(
                RichText::new(if n == 1 { "1 run".to_string() } else { format!("{n} runs") })
                    .size(10.0)
                    .color(theme::INK3),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if theme::chip(ui, "Clear all", None).clicked() {
                    self.resumes.clear_generations();
                }
            });
        });
        ui.add_space(4.0);

        let rows: Vec<HistoryRow> = self
            .resumes
            .generations
            .iter()
            .map(|g| HistoryRow {
                id: g.id,
                title: g.display_title(),
                score: g.after_score.as_ref().or(g.before_score.as_ref()).map(|s| s.score),
                delta: g.score_delta(),
                has_output: !g.generated_text.is_empty(),
            })
            .collect();

        egui::ScrollArea::vertical().id_salt("gen-list").auto_shrink([false, false]).show(ui, |ui| {
            let mut open = None;
            let mut delete = None;
            for HistoryRow { id, title, score, delta, has_output } in rows {
                egui::Frame::none()
                    .fill(theme::PREVIEW)
                    .rounding(Rounding::same(8.0))
                    .stroke(Stroke::new(0.5, theme::HAIRLINE))
                    .inner_margin(Margin::symmetric(10.0, 8.0))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            if let Some(s) = score {
                                score_pip(ui, s);
                            }
                            // Right-hand controls claim their width first, so
                            // the title truncates against them instead of
                            // running underneath.
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                if theme::chip(ui, "Delete", None).clicked() {
                                    delete = Some(id);
                                }
                                if !has_output {
                                    ui.label(RichText::new("score only").size(9.5).color(theme::INK_MUTED));
                                }
                                if let Some(d) = delta {
                                    delta_chip(ui, d);
                                }
                                ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                                    let label =
                                        egui::Label::new(RichText::new(&title).size(12.0).color(theme::INK))
                                            .truncate()
                                            .sense(Sense::click());
                                    if ui.add(label).on_hover_text("Open this run").clicked() {
                                        open = Some(id);
                                    }
                                });
                            });
                        });
                    });
                ui.add_space(5.0);
            }
            if let Some(id) = open {
                self.open_generation = Some(id);
            }
            if let Some(id) = delete {
                self.resumes.delete_generation(id);
            }
        });
    }

    fn draw_generation_detail(&mut self, ui: &mut egui::Ui, id: u64) {
        let Some(g) = self.resumes.generation(id) else { return };
        let (title, jd, text, before, after) = (
            g.display_title(),
            g.jd.clone(),
            g.generated_text.clone(),
            g.before_score.clone(),
            g.after_score.clone(),
        );
        ui.horizontal(|ui| {
            if theme::chip(ui, "‹ Back", None).clicked() {
                self.open_generation = None;
            }
            ui.add(egui::Label::new(RichText::new(&title).size(12.5).color(theme::INK).strong()).truncate());
        });
        ui.add_space(8.0);

        egui::ScrollArea::vertical().id_salt(("gen-detail", id)).auto_shrink([false, false]).show(ui, |ui| {
            if before.is_some() || after.is_some() {
                egui::Frame::none()
                    .fill(theme::PREVIEW)
                    .rounding(Rounding::same(8.0))
                    .inner_margin(Margin::same(12.0))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| match (&before, &after) {
                            (Some(b), Some(a)) => {
                                score_dial(ui, b.score, "Before");
                                ui.add_space(6.0);
                                delta_chip(ui, a.score - b.score);
                                ui.add_space(6.0);
                                score_dial(ui, a.score, "After");
                            }
                            (Some(b), None) => score_dial(ui, b.score, "Score"),
                            (None, Some(a)) => score_dial(ui, a.score, "Score"),
                            (None, None) => {}
                        });
                        if let Some(s) = after.as_ref().or(before.as_ref()) {
                            if !s.missing.is_empty() {
                                ui.add_space(6.0);
                                keyword_row(ui, "Missing", &s.missing, theme::AMBER);
                            }
                        }
                    });
                ui.add_space(10.0);
            }

            if !text.is_empty() {
                ui.horizontal_wrapped(|ui| {
                    let key = ui.id().with(("detail-copy", id));
                    self.copy_chip(ui, key, &text);
                    if theme::chip(ui, "Save as…", None).clicked() {
                        self.save_text_as("tailored-resume.md", &text);
                    }
                    if theme::chip(ui, "Re-score", None).clicked() {
                        self.start_score(id, true);
                    }
                });
                ui.add_space(6.0);
                egui::Frame::none()
                    .fill(theme::PREVIEW)
                    .rounding(Rounding::same(8.0))
                    .inner_margin(Margin::same(12.0))
                    .show(ui, |ui| render_markdown(ui, &text, 13.0, theme::INK));
                ui.add_space(10.0);
            }

            if !jd.trim().is_empty() {
                theme::section_header(ui, "Job description", false);
                egui::Frame::none()
                    .fill(theme::PREVIEW)
                    .rounding(Rounding::same(8.0))
                    .inner_margin(Margin::same(12.0))
                    .show(ui, |ui| {
                        ui.add(egui::Label::new(RichText::new(&jd).size(11.5).color(theme::INK2)).wrap());
                    });
            }
        });
    }
}

/// One row of the Generations list, snapshotted so the store isn't borrowed
/// while the list is being drawn.
struct HistoryRow {
    id: u64,
    title: String,
    /// Latest score available — the tailored one when there is one.
    score: Option<i32>,
    delta: Option<i32>,
    has_output: bool,
}

fn band_color(band: ScoreBand) -> egui::Color32 {
    match band {
        ScoreBand::Good => theme::GREEN,
        ScoreBand::Fair => theme::AMBER,
        ScoreBand::Poor => theme::RED,
    }
}

/// Big number + caption, tinted by score band.
fn score_dial(ui: &mut egui::Ui, score: i32, caption: &str) {
    let color = band_color(ResumeScore { score, ..Default::default() }.band());
    let (rect, _) = ui.allocate_exact_size(vec2(62.0, 46.0), Sense::hover());
    if !ui.is_rect_visible(rect) {
        return;
    }
    let p = ui.painter();
    p.rect(rect, Rounding::same(8.0), color.gamma_multiply(0.12), Stroke::new(0.5, color.gamma_multiply(0.45)));
    p.text(
        egui::pos2(rect.center().x, rect.top() + 17.0),
        egui::Align2::CENTER_CENTER,
        score.to_string(),
        egui::FontId::proportional(19.0),
        color,
    );
    p.text(
        egui::pos2(rect.center().x, rect.bottom() - 11.0),
        egui::Align2::CENTER_CENTER,
        caption,
        egui::FontId::proportional(9.5),
        theme::INK3,
    );
}

/// Small "+27" pill; green for gains, muted for none, red for a regression.
fn delta_chip(ui: &mut egui::Ui, delta: i32) {
    let (color, text) = if delta > 0 {
        (theme::GREEN, format!("+{delta}"))
    } else if delta < 0 {
        (theme::RED, format!("{delta}"))
    } else {
        (theme::INK3, "0".to_string())
    };
    let font = egui::FontId::proportional(11.0);
    let w = ui.fonts(|f| f.layout_no_wrap(text.clone(), font.clone(), color).size().x);
    let (rect, _) = ui.allocate_exact_size(vec2(w + 16.0, 20.0), Sense::hover());
    if !ui.is_rect_visible(rect) {
        return;
    }
    ui.painter().rect(rect, Rounding::same(10.0), color.gamma_multiply(0.14), Stroke::NONE);
    ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, text, font, color);
}

/// Score dot for a history row.
fn score_pip(ui: &mut egui::Ui, score: i32) {
    let color = band_color(ResumeScore { score, ..Default::default() }.band());
    let (rect, _) = ui.allocate_exact_size(vec2(30.0, 20.0), Sense::hover());
    ui.painter().rect(rect, Rounding::same(6.0), color.gamma_multiply(0.14), Stroke::NONE);
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        score.to_string(),
        egui::FontId::proportional(11.0),
        color,
    );
}

/// "Missing: Kubernetes · gRPC · Terraform" as tinted chips.
fn keyword_row(ui: &mut egui::Ui, label: &str, words: &[String], color: egui::Color32) {
    ui.horizontal_wrapped(|ui| {
        ui.label(RichText::new(label).size(10.0).color(theme::INK3).strong());
        for w in words {
            let font = egui::FontId::proportional(10.5);
            let tw = ui.fonts(|f| f.layout_no_wrap(w.clone(), font.clone(), color).size().x);
            let (rect, _) = ui.allocate_exact_size(vec2(tw + 14.0, 18.0), Sense::hover());
            if !ui.is_rect_visible(rect) {
                continue;
            }
            ui.painter().rect(rect, Rounding::same(9.0), color.gamma_multiply(0.13), Stroke::NONE);
            ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, w, font, color);
        }
    });
}
