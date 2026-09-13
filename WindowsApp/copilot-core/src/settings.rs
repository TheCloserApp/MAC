//! Persisted settings, stored as JSON under the OS config dir.
//!
//! On macOS the app kept these in `UserDefaults`; on Windows we write a single
//! `config.json` in `%APPDATA%\thecloser\`. Every field has a serde default so
//! a config written by an older build still loads.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::ai::ProviderKeys;
use crate::modes::SessionMode;

/// Which audio stream feeds transcription.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum AudioSource {
    /// The default capture device (your microphone). Use when the interviewer
    /// comes through your speakers and you want to transcribe yourself, or for
    /// testing.
    Microphone,
    /// WASAPI loopback of the default render device — captures whatever is
    /// playing through your speakers/headset, i.e. the interviewer. This is the
    /// primary mode for an interview copilot.
    #[default]
    System,
}

impl AudioSource {
    pub fn label(self) -> &'static str {
        match self {
            AudioSource::Microphone => "Microphone",
            AudioSource::System => "System audio (interviewer)",
        }
    }
}

/// Which cloud speech-to-text backend transcribes audio chunks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SttProvider {
    /// OpenAI `audio/transcriptions` (Whisper / gpt-4o-transcribe). Reuses the
    /// OpenAI key.
    #[default]
    OpenAi,
    /// ElevenLabs Scribe (`speech-to-text`, `scribe_v1`). Uses the ElevenLabs key.
    ElevenLabs,
}

impl SttProvider {
    pub fn label(self) -> &'static str {
        match self {
            SttProvider::OpenAi => "OpenAI Whisper",
            SttProvider::ElevenLabs => "ElevenLabs Scribe",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    // ── Provider API keys ────────────────────────────────────────────────
    pub anthropic_key: String,
    pub openai_key: String,
    pub moonshot_key: String,
    pub grok_key: String,
    pub deepseek_key: String,
    pub nvidia_key: String,
    pub openrouter_key: String,
    /// ElevenLabs key — only used for Scribe transcription.
    pub elevenlabs_key: String,

    // ── Model / mode ─────────────────────────────────────────────────────
    pub selected_model: String,
    pub session_mode: SessionMode,

    // ── Audio / transcription ────────────────────────────────────────────
    pub audio_source: AudioSource,
    pub stt_provider: SttProvider,
    /// OpenAI transcription model id (`whisper-1`, `gpt-4o-transcribe`, …).
    pub stt_model: String,
    /// Auto-send a finished question to the AI after a pause (interview flow).
    pub auto_send: bool,
    /// Silence grace before auto-send fires, in milliseconds.
    pub auto_send_silence_ms: u64,

    // ── User context ─────────────────────────────────────────────────────
    pub user_name: String,
    pub user_role: String,
    pub user_company: String,
    /// Free-text context (résumé text, job description, notes) injected as the
    /// conversation anchor so answers are grounded in the user's real material.
    pub context: String,

    // ── Window geometry (logical px) ─────────────────────────────────────
    pub panel_x: f32,
    pub panel_y: f32,
    pub panel_width: f32,
    pub panel_height: f32,
    /// UI zoom multiplier.
    pub font_scale: f32,

    // ── Appearance ───────────────────────────────────────────────────────
    /// Overall overlay opacity (0.2–1.0) — fade the whole thing over a call.
    pub opacity: f32,
    /// Card-background opacity (0.2–1.0), independent of the content above it.
    pub background_opacity: f32,
    /// Show the per-answer token counts.
    pub show_token_counts: bool,
    /// Stream an answer automatically as questions arrive. Off means the user
    /// presses Send when the interviewer has actually finished.
    pub auto_generate: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            anthropic_key: String::new(),
            openai_key: String::new(),
            moonshot_key: String::new(),
            grok_key: String::new(),
            deepseek_key: String::new(),
            nvidia_key: String::new(),
            openrouter_key: String::new(),
            elevenlabs_key: String::new(),
            selected_model: "claude-opus-4-8".to_string(),
            session_mode: SessionMode::Interview,
            audio_source: AudioSource::System,
            stt_provider: SttProvider::OpenAi,
            stt_model: "whisper-1".to_string(),
            auto_send: true,
            auto_send_silence_ms: 1100,
            user_name: String::new(),
            user_role: String::new(),
            user_company: String::new(),
            context: String::new(),
            panel_x: 80.0,
            panel_y: 60.0,
            panel_width: 460.0,
            panel_height: 560.0,
            font_scale: 1.0,
            opacity: 1.0,
            background_opacity: 1.0,
            show_token_counts: false,
            auto_generate: true,
        }
    }
}

impl Settings {
    /// `%APPDATA%\thecloser\config.json` (or the platform equivalent).
    /// Goes through [`crate::store::config_dir`] so a redirected config
    /// directory moves the settings file along with the libraries.
    pub fn default_path() -> PathBuf {
        crate::store::config_dir().join("config.json")
    }

    /// Load from `path`, returning defaults if the file is missing or corrupt
    /// (never fails — a broken config shouldn't stop the app from launching).
    pub fn load(path: &Path) -> Settings {
        match std::fs::read_to_string(path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Settings::default(),
        }
    }

    /// Persist to `path`, creating parent directories as needed.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    /// Bundle the seven AI provider keys for [`crate::models::route`].
    pub fn provider_keys(&self) -> ProviderKeys {
        ProviderKeys {
            anthropic: self.anthropic_key.clone(),
            openai: self.openai_key.clone(),
            moonshot: self.moonshot_key.clone(),
            grok: self.grok_key.clone(),
            deepseek: self.deepseek_key.clone(),
            nvidia: self.nvidia_key.clone(),
            openrouter: self.openrouter_key.clone(),
        }
    }

    /// True when the currently selected model's provider has no key set —
    /// drives the "Add an API key to begin" prompt.
    pub fn provider_keys_missing(&self) -> bool {
        crate::models::route(&self.selected_model, &self.provider_keys())
            .api_key
            .trim()
            .is_empty()
    }

    /// The key for the STT backend the user selected, or an empty string.
    pub fn stt_key(&self) -> &str {
        match self.stt_provider {
            SttProvider::OpenAi => &self.openai_key,
            SttProvider::ElevenLabs => &self.elevenlabs_key,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_disk() {
        let dir = std::env::temp_dir().join(format!("thecloser-test-{}", std::process::id()));
        let path = dir.join("config.json");
        let s = Settings {
            anthropic_key: "sk-ant-xyz".into(),
            user_name: "Ada".into(),
            session_mode: SessionMode::Meeting,
            ..Default::default()
        };
        s.save(&path).unwrap();

        let loaded = Settings::load(&path);
        assert_eq!(loaded.anthropic_key, "sk-ant-xyz");
        assert_eq!(loaded.user_name, "Ada");
        assert_eq!(loaded.session_mode, SessionMode::Meeting);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_file_yields_defaults() {
        let s = Settings::load(Path::new("/nonexistent/thecloser/config.json"));
        assert_eq!(s.selected_model, "claude-opus-4-8");
        assert_eq!(s.session_mode, SessionMode::Interview);
    }

    #[test]
    fn partial_json_keeps_defaults_for_missing_fields() {
        // A config from an older build that only knew about a couple of fields.
        let dir = std::env::temp_dir().join(format!("thecloser-partial-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        std::fs::write(&path, r#"{ "openai_key": "sk-oai" }"#).unwrap();
        let s = Settings::load(&path);
        assert_eq!(s.openai_key, "sk-oai");
        assert_eq!(s.stt_model, "whisper-1"); // default preserved
        assert!(s.auto_send);
        std::fs::remove_dir_all(&dir).ok();
    }
}
