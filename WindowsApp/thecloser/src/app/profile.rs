//! The Profile surface — the macOS Preferences window, folded into the
//! overlay as a tab rail: AI keys and model, transcription, your profile,
//! panel appearance, Quick Ask behaviour, the prompt library, and the
//! shortcut reference.

use egui::{vec2, Align, Layout, Margin, RichText, Rounding, Sense, Stroke};

use copilot_core::models::available_models;
use copilot_core::prompts::PromptKind;
use copilot_core::settings::{AudioSource, SttProvider};

use super::{key_field, labeled, App, ProfileTab, PromptDraft};
use crate::theme;

impl App {
    pub(super) fn draw_settings(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Profile & settings").size(15.0).color(theme::INK).strong());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                theme::dot(ui, theme::mode_color(self.settings.session_mode), 3.5);
            });
        });
        ui.add_space(8.0);

        // Tab rail — wraps rather than scrolls, so a narrow overlay never
        // hides a tab off the right edge.
        ui.horizontal_wrapped(|ui| {
            for tab in ProfileTab::ALL {
                if theme::segment_pill(ui, tab.title(), self.profile_tab == tab).clicked() {
                    self.profile_tab = tab;
                }
            }
        });
        ui.add_space(4.0);
        ui.separator();

        if !self.status.is_empty() {
            let status = self.status.clone();
            ui.horizontal(|ui| {
                ui.add(egui::Label::new(RichText::new(&status).size(10.5).color(theme::AMBER)).wrap());
                if theme::chip(ui, "Dismiss", None).clicked() {
                    self.status.clear();
                }
            });
        }

        let mut area = egui::ScrollArea::vertical().id_salt("profile-body").auto_shrink([false, false]);
        if let Some(offset) = self.demo_scroll() {
            area = area.vertical_scroll_offset(offset);
        }
        area.show(ui, |ui| {
            ui.add_space(6.0);
            match self.profile_tab {
                ProfileTab::Ai => self.tab_ai(ui),
                ProfileTab::Transcription => self.tab_transcription(ui),
                ProfileTab::Profile => self.tab_profile(ui),
                ProfileTab::Panel => self.tab_panel(ui),
                ProfileTab::QuickAsk => self.tab_quick_ask(ui),
                ProfileTab::Prompts => self.tab_prompts(ui),
                ProfileTab::Shortcuts => self.tab_shortcuts(ui),
            }
            ui.add_space(10.0);
            ui.horizontal(|ui| {
                if theme::primary_capsule(ui, "Save").clicked() {
                    self.persist();
                    self.status = "Saved.".into();
                }
                // Full path on hover only — it's long enough to blow out the
                // panel width, and the folder is what matters at a glance.
                let full = self.settings_path.display().to_string();
                let short = self
                    .settings_path
                    .parent()
                    .and_then(|p| p.file_name())
                    .map(|f| format!("Config: …/{}/config.json", f.to_string_lossy()))
                    .unwrap_or_else(|| full.clone());
                ui.add(
                    egui::Label::new(RichText::new(short).size(10.0).color(theme::INK_MUTED))
                        .truncate(),
                )
                .on_hover_text(full);
            });
            ui.add_space(6.0);
        });

        self.draw_prompt_sheet(ctx);
    }

    fn tab_ai(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Provider keys", false);
        ui.label(
            RichText::new("Keys stay on this PC, in the config file below. Only the provider you pick is contacted.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
        ui.add_space(4.0);
        key_field(ui, "Anthropic", &mut self.settings.anthropic_key);
        key_field(ui, "OpenAI", &mut self.settings.openai_key);
        key_field(ui, "Kimi (Moonshot)", &mut self.settings.moonshot_key);
        key_field(ui, "Grok (xAI)", &mut self.settings.grok_key);
        key_field(ui, "DeepSeek", &mut self.settings.deepseek_key);
        key_field(ui, "NVIDIA NIM", &mut self.settings.nvidia_key);
        key_field(ui, "OpenRouter", &mut self.settings.openrouter_key);

        ui.add_space(12.0);
        theme::section_header(ui, "Default model", false);
        ui.horizontal(|ui| {
            self.model_picker(ui);
            if self.settings.provider_keys_missing() {
                ui.label(RichText::new("no key for this provider").size(10.5).color(theme::AMBER));
            }
        });

        ui.add_space(12.0);
        theme::section_header(ui, "Model catalog", false);
        let selected = self.settings.selected_model.clone();
        let mut pick = None;
        let mut last = "";
        for m in available_models() {
            if m.provider != last {
                ui.add_space(4.0);
                ui.label(RichText::new(m.provider.to_uppercase()).size(9.0).color(theme::CHATGPT).strong());
                last = m.provider;
            }
            let is_sel = selected == m.id;
            egui::Frame::none()
                .fill(if is_sel { theme::CONTROL } else { theme::PREVIEW })
                .rounding(Rounding::same(7.0))
                .stroke(Stroke::new(0.5, if is_sel { theme::STRONG_HAIRLINE } else { theme::HAIRLINE }))
                .inner_margin(Margin::symmetric(10.0, 6.0))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        let label = egui::Label::new(RichText::new(m.name).size(11.5).color(theme::INK))
                            .sense(Sense::click());
                        if ui.add(label).clicked() {
                            pick = Some(m.id.to_string());
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if is_sel {
                                ui.label(RichText::new("default").size(9.5).color(theme::CHATGPT));
                            }
                            ui.label(RichText::new(m.id).size(9.5).color(theme::INK_MUTED));
                        });
                    });
                });
            ui.add_space(3.0);
        }
        if let Some(id) = pick {
            self.settings.selected_model = id;
            self.persist();
        }
    }

    fn tab_transcription(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Engine", false);
        ui.horizontal(|ui| {
            for p in [SttProvider::OpenAi, SttProvider::ElevenLabs] {
                if theme::segment_pill(ui, p.label(), self.settings.stt_provider == p).clicked() {
                    self.settings.stt_provider = p;
                    self.persist();
                }
            }
        });
        ui.add_space(8.0);
        if self.settings.stt_provider == SttProvider::OpenAi {
            labeled(ui, "Whisper model", &mut self.settings.stt_model);
            ui.label(
                RichText::new("Uses your OpenAI key. `whisper-1` is cheapest; `gpt-4o-transcribe` is more accurate.")
                    .size(10.5)
                    .color(theme::INK_MUTED),
            );
        } else {
            key_field(ui, "ElevenLabs key", &mut self.settings.elevenlabs_key);
        }

        ui.add_space(12.0);
        theme::section_header(ui, "Audio source", false);
        ui.horizontal_wrapped(|ui| {
            for src in [AudioSource::System, AudioSource::Microphone] {
                if theme::segment_pill(ui, src.label(), self.settings.audio_source == src).clicked() {
                    self.settings.audio_source = src;
                    self.persist();
                }
            }
        });
        ui.label(
            RichText::new("System audio captures the interviewer through your speakers or headset — that's the one you want in a call.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
    }

    fn tab_profile(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "You", false);
        ui.label(
            RichText::new("Substituted into the system prompt as {NAME}, {ROLE}, {COMPANY}.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
        ui.add_space(4.0);
        labeled(ui, "Name", &mut self.settings.user_name);
        labeled(ui, "Role", &mut self.settings.user_role);
        labeled(ui, "Company", &mut self.settings.user_company);

        ui.add_space(12.0);
        theme::section_header(ui, "Context", true);
        ui.label(
            RichText::new("Sent with every session, ahead of the conversation.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
        ui.add(
            egui::TextEdit::multiline(&mut self.settings.context)
                .desired_rows(5)
                .desired_width(f32::INFINITY)
                .margin(Margin::symmetric(10.0, 8.0))
                .hint_text("Résumé / job description / notes…"),
        );

        ui.add_space(12.0);
        theme::section_header(ui, "Attached files", true);
        if self.attachments.is_empty() {
            ui.label(RichText::new("None — attach them on the Interview tab.").size(10.5).color(theme::INK_MUTED));
        } else {
            let names: Vec<String> = self.attachments.iter().map(|a| a.name.clone()).collect();
            let mut remove = None;
            for (i, name) in names.iter().enumerate() {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(name).size(11.0).color(theme::INK2));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if theme::chip(ui, "Remove", None).clicked() {
                            remove = Some(i);
                        }
                    });
                });
            }
            if let Some(i) = remove {
                self.attachments.remove(i);
            }
        }
    }

    fn tab_panel(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Appearance", false);
        let mut changed = false;
        ui.horizontal(|ui| {
            ui.label(RichText::new("Overlay opacity").size(11.5).color(theme::INK2));
            changed |= ui
                .add(egui::Slider::new(&mut self.settings.opacity, 0.2..=1.0).show_value(false))
                .changed();
            ui.label(
                RichText::new(format!("{}%", (self.settings.opacity * 100.0).round() as i32))
                    .size(11.0)
                    .color(theme::INK3)
                    .monospace(),
            );
        });
        ui.horizontal(|ui| {
            ui.label(RichText::new("Background").size(11.5).color(theme::INK2));
            changed |= ui
                .add(egui::Slider::new(&mut self.settings.background_opacity, 0.2..=1.0).show_value(false))
                .changed();
            ui.label(
                RichText::new(format!("{}%", (self.settings.background_opacity * 100.0).round() as i32))
                    .size(11.0)
                    .color(theme::INK3)
                    .monospace(),
            );
        });
        ui.label(
            RichText::new("Fade the whole overlay, or just its card backgrounds, so it sits lightly over a call window.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );

        ui.add_space(10.0);
        ui.horizontal(|ui| {
            ui.label(RichText::new("UI scale").size(11.5).color(theme::INK2));
            if ui
                .add(egui::Slider::new(&mut self.settings.font_scale, 0.8..=1.6).show_value(false))
                .changed()
            {
                ui.ctx().set_zoom_factor(self.settings.font_scale);
                changed = true;
            }
            ui.label(
                RichText::new(format!("{:.0}%", self.settings.font_scale * 100.0))
                    .size(11.0)
                    .color(theme::INK3)
                    .monospace(),
            );
        });

        ui.add_space(10.0);
        changed |= ui.checkbox(&mut self.settings.show_token_counts, "Show token counts").changed();
        if changed {
            self.persist();
        }

        ui.add_space(12.0);
        theme::section_header(ui, "Screen capture", false);
        ui.label(
            RichText::new(if cfg!(windows) {
                "This window is excluded from screen capture — invisible in Zoom, Meet, Teams, OBS, and Game Bar, while staying visible to you."
            } else {
                "Capture exclusion is a Windows feature; this preview build doesn't hide the overlay from recordings."
            })
            .size(10.5)
            .color(theme::INK_MUTED),
        );
    }

    fn tab_quick_ask(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Answering", false);
        let mut changed = false;
        changed |= ui
            .checkbox(&mut self.settings.auto_generate, "Auto-generate answers as questions arrive")
            .changed();
        changed |= ui
            .checkbox(&mut self.settings.auto_send, "Auto-send a question after a pause")
            .changed();
        ui.horizontal(|ui| {
            ui.label(RichText::new("Pause before send").size(11.5).color(theme::INK2));
            changed |= ui
                .add(egui::Slider::new(&mut self.settings.auto_send_silence_ms, 400..=3000).suffix(" ms"))
                .changed();
        });
        ui.label(
            RichText::new("How long the interviewer has to stop talking before the question is sent.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
        if changed {
            self.persist();
        }

        ui.add_space(12.0);
        theme::section_header(ui, "Push-to-talk", false);
        ui.label(
            RichText::new("Hold Ctrl+Alt+Q anywhere to ask something with your own voice — release and it sends. Ctrl+Alt+C explains whatever is on the clipboard.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
    }

    /// The prompt library — create, edit, activate, and delete saved prompts
    /// for all three uses.
    fn tab_prompts(&mut self, ui: &mut egui::Ui) {
        for kind in PromptKind::ALL {
            theme::section_header(ui, kind.display_name(), false);
            let active_id = self.prompts.active(kind).map(|p| p.id);
            let rows: Vec<(u64, String, String)> = self
                .prompts
                .of_kind(kind)
                .map(|p| (p.id, p.name.clone(), p.content.clone()))
                .collect();

            if rows.is_empty() {
                ui.label(RichText::new("None saved.").size(10.5).color(theme::INK_MUTED));
            }
            let mut activate = None;
            let mut edit = None;
            for (id, name, content) in rows {
                let is_active = active_id == Some(id);
                egui::Frame::none()
                    .fill(if is_active { theme::CONTROL } else { theme::PREVIEW })
                    .rounding(Rounding::same(7.0))
                    .stroke(Stroke::new(0.5, if is_active { theme::STRONG_HAIRLINE } else { theme::HAIRLINE }))
                    .inner_margin(Margin::symmetric(10.0, 7.0))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            let label = egui::Label::new(RichText::new(&name).size(11.5).color(theme::INK))
                                .sense(Sense::click());
                            if ui.add(label).on_hover_text("Use this prompt").clicked() {
                                activate = Some(if is_active { None } else { Some(id) });
                            }
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                if theme::chip(ui, "Edit", None).clicked() {
                                    edit = Some((id, name.clone(), content.clone(), kind));
                                }
                                if is_active {
                                    ui.label(RichText::new("active").size(9.5).color(theme::CHATGPT));
                                }
                            });
                        });
                    });
                ui.add_space(4.0);
            }
            if let Some(next) = activate {
                self.prompts.set_active(kind, next);
            }
            if let Some((id, name, content, kind)) = edit {
                self.prompt_draft = Some(PromptDraft { editing: Some(id), name, content, kind });
            }
            if theme::chip(ui, "New prompt…", None).clicked() {
                self.prompt_draft =
                    Some(PromptDraft { editing: None, name: String::new(), content: String::new(), kind });
            }
            ui.add_space(12.0);
        }
        ui.label(
            RichText::new("With nothing active, sessions use the built-in prompt for the current mode, and résumé tasks use their defaults.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
    }

    fn tab_shortcuts(&mut self, ui: &mut egui::Ui) {
        theme::section_header(ui, "Global shortcuts", false);
        ui.label(
            RichText::new("These work from any app — you never have to focus the overlay.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
        ui.add_space(6.0);
        for (keys, what) in [
            ("Ctrl + Alt + Space", "Show / hide the overlay"),
            ("Ctrl + Alt + T", "Start / stop listening"),
            ("Ctrl + Alt + Q", "Hold to ask with your own voice"),
            ("Ctrl + Alt + C", "Explain what's on the clipboard"),
            ("Ctrl + Alt + ← ↑ ↓ →", "Move the overlay"),
            ("Ctrl + Shift + ← ↑ ↓ →", "Resize the overlay"),
        ] {
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(vec2(168.0, 22.0), Sense::hover());
                ui.painter().rect(
                    rect,
                    Rounding::same(6.0),
                    theme::PREVIEW,
                    Stroke::new(0.5, theme::HAIRLINE),
                );
                ui.painter().text(
                    egui::pos2(rect.left() + 9.0, rect.center().y),
                    egui::Align2::LEFT_CENTER,
                    keys,
                    egui::FontId::monospace(10.5),
                    theme::INK2,
                );
                ui.label(RichText::new(what).size(11.0).color(theme::INK2));
            });
            ui.add_space(3.0);
        }
        ui.add_space(8.0);
        ui.label(
            RichText::new("Drag the waveform to move the window; drag the bottom-right corner to resize it.")
                .size(10.5)
                .color(theme::INK_MUTED),
        );
    }
}
