//! The saved-system-prompt library.
//!
//! Port of the macOS `PromptStore` / `PromptPreset`. One store backs three
//! surfaces — conversation prompts (used as the session system prompt),
//! résumé-generation prompts, and résumé-scoring prompts — each selected
//! independently. Seeds one conversation preset per built-in mode, linked to
//! that mode, so picking a mode activates its prompt and the library is never
//! empty on first run.

use serde::{Deserialize, Serialize};

use crate::modes::SessionMode;
use crate::store::{self, new_id, now_secs};

const FILENAME: &str = "prompts.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PromptKind {
    /// System prompt for interview / meeting / call / general sessions.
    #[default]
    Conversation,
    /// Override for the résumé-generation system prompt.
    ResumeGeneration,
    /// Override for the résumé-scoring system prompt.
    ResumeScoring,
}

impl PromptKind {
    pub const ALL: [PromptKind; 3] =
        [PromptKind::Conversation, PromptKind::ResumeGeneration, PromptKind::ResumeScoring];

    pub fn display_name(self) -> &'static str {
        match self {
            PromptKind::Conversation => "Conversation",
            PromptKind::ResumeGeneration => "Résumé generation",
            PromptKind::ResumeScoring => "Résumé scoring",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PromptPreset {
    pub id: u64,
    pub name: String,
    pub content: String,
    pub kind: PromptKind,
    /// When set, this preset is the default prompt for that session mode —
    /// selecting the mode activates it.
    pub linked_mode: Option<SessionMode>,
    pub created_at: u64,
    pub updated_at: u64,
}

impl Default for PromptPreset {
    fn default() -> Self {
        PromptPreset {
            id: 0,
            name: String::new(),
            content: String::new(),
            kind: PromptKind::Conversation,
            linked_mode: None,
            created_at: 0,
            updated_at: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct PromptStore {
    pub presets: Vec<PromptPreset>,
    /// Active conversation preset — overrides the built-in mode prompt.
    pub active_id: Option<u64>,
    pub active_generation_id: Option<u64>,
    pub active_scoring_id: Option<u64>,
    /// Where this library is persisted. Skipped in the file itself, and left
    /// empty for a detached store (tests) so mutations never touch the disk.
    #[serde(skip)]
    path: std::path::PathBuf,
}

impl PromptStore {
    pub fn load() -> Self {
        let path = store::library_path(FILENAME);
        let mut store: PromptStore = store::load(&path);
        store.path = path;
        if store.presets.is_empty() {
            store.presets = Self::seeded();
        }
        // Drop dangling selections (a preset deleted in an older build).
        store.active_id = store.active_id.filter(|id| store.find(*id).is_some());
        store.active_generation_id =
            store.active_generation_id.filter(|id| store.find(*id).is_some());
        store.active_scoring_id = store.active_scoring_id.filter(|id| store.find(*id).is_some());
        store
    }

    pub fn save(&self) {
        if self.path.as_os_str().is_empty() {
            return; // detached store — nothing to write
        }
        let _ = store::save(&self.path, self);
    }

    fn seeded() -> Vec<PromptPreset> {
        SessionMode::ALL
            .iter()
            .map(|&mode| PromptPreset {
                id: new_id(),
                name: mode.display_name().to_string(),
                content: mode.system_prompt().to_string(),
                kind: PromptKind::Conversation,
                linked_mode: Some(mode),
                created_at: now_secs(),
                updated_at: now_secs(),
            })
            .collect()
    }

    // ── Queries ─────────────────────────────────────────────────────────────

    pub fn find(&self, id: u64) -> Option<&PromptPreset> {
        self.presets.iter().find(|p| p.id == id)
    }

    pub fn of_kind(&self, kind: PromptKind) -> impl Iterator<Item = &PromptPreset> {
        self.presets.iter().filter(move |p| p.kind == kind)
    }

    /// The active preset for `kind`, if one is selected and still exists.
    pub fn active(&self, kind: PromptKind) -> Option<&PromptPreset> {
        let id = match kind {
            PromptKind::Conversation => self.active_id,
            PromptKind::ResumeGeneration => self.active_generation_id,
            PromptKind::ResumeScoring => self.active_scoring_id,
        }?;
        self.presets.iter().find(|p| p.id == id && p.kind == kind)
    }

    pub fn set_active(&mut self, kind: PromptKind, id: Option<u64>) {
        match kind {
            PromptKind::Conversation => self.active_id = id,
            PromptKind::ResumeGeneration => self.active_generation_id = id,
            PromptKind::ResumeScoring => self.active_scoring_id = id,
        }
        self.save();
    }

    /// The user's override preset for a built-in mode, if they made one.
    pub fn linked(&self, mode: SessionMode) -> Option<&PromptPreset> {
        self.presets
            .iter()
            .find(|p| p.kind == PromptKind::Conversation && p.linked_mode == Some(mode))
    }

    // ── Mutations ───────────────────────────────────────────────────────────

    pub fn add(&mut self, name: &str, content: &str, kind: PromptKind) -> u64 {
        let id = new_id();
        self.presets.push(PromptPreset {
            id,
            name: name.trim().to_string(),
            content: content.trim().to_string(),
            kind,
            linked_mode: None,
            created_at: now_secs(),
            updated_at: now_secs(),
        });
        self.save();
        id
    }

    pub fn update(&mut self, id: u64, name: &str, content: &str) {
        if let Some(p) = self.presets.iter_mut().find(|p| p.id == id) {
            p.name = name.trim().to_string();
            p.content = content.trim().to_string();
            p.updated_at = now_secs();
        }
        self.save();
    }

    pub fn delete(&mut self, id: u64) {
        self.presets.retain(|p| p.id != id);
        for slot in [&mut self.active_id, &mut self.active_generation_id, &mut self.active_scoring_id] {
            if *slot == Some(id) {
                *slot = None;
            }
        }
        self.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store_with_seed() -> PromptStore {
        PromptStore { presets: PromptStore::seeded(), ..Default::default() }
    }

    #[test]
    fn seeds_one_conversation_preset_per_mode() {
        let s = store_with_seed();
        assert_eq!(s.presets.len(), SessionMode::ALL.len());
        for mode in SessionMode::ALL {
            let linked = s.linked(mode).expect("every mode is seeded");
            assert_eq!(linked.content, mode.system_prompt());
            assert_eq!(linked.kind, PromptKind::Conversation);
        }
    }

    #[test]
    fn active_is_scoped_to_its_kind() {
        let mut s = store_with_seed();
        let gen = s.add("Tailor hard", "rewrite aggressively", PromptKind::ResumeGeneration);
        // Selecting it as a *conversation* prompt must not resolve — the kinds
        // are independent slots.
        s.active_id = Some(gen);
        assert!(s.active(PromptKind::Conversation).is_none());

        s.active_generation_id = Some(gen);
        assert_eq!(s.active(PromptKind::ResumeGeneration).unwrap().name, "Tailor hard");
    }

    #[test]
    fn delete_clears_every_active_slot_referencing_it() {
        let mut s = store_with_seed();
        let id = s.add("Temp", "body", PromptKind::ResumeScoring);
        s.active_scoring_id = Some(id);
        s.delete(id);
        assert!(s.find(id).is_none());
        assert_eq!(s.active_scoring_id, None);
    }

    #[test]
    fn update_trims_and_stamps() {
        let mut s = store_with_seed();
        let id = s.add("A", "b", PromptKind::Conversation);
        s.update(id, "  Renamed  ", "  new body  ");
        let p = s.find(id).unwrap();
        assert_eq!(p.name, "Renamed");
        assert_eq!(p.content, "new body");
    }

    #[test]
    fn of_kind_filters() {
        let mut s = store_with_seed();
        s.add("G", "g", PromptKind::ResumeGeneration);
        assert_eq!(s.of_kind(PromptKind::ResumeGeneration).count(), 1);
        assert_eq!(s.of_kind(PromptKind::Conversation).count(), SessionMode::ALL.len());
    }

    #[test]
    fn a_detached_store_never_writes_to_the_real_library() {
        // Regression: mutating a store built in memory used to persist into
        // the user's config directory, so running the tests edited their
        // actual prompt library.
        let real = crate::store::library_path("prompts.json");
        let before = std::fs::read(&real).ok();

        let mut s = store_with_seed();
        s.add("Definitely not yours", "junk", PromptKind::Conversation);
        s.set_active(PromptKind::Conversation, None);
        s.delete(s.presets[0].id);

        assert_eq!(std::fs::read(&real).ok(), before, "detached store touched the real library");
    }
}
