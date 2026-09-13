//! The résumé library, tailoring runs, and ATS scoring.
//!
//! Port of the macOS `ResumeStore` / `ResumePreset` / `ResumeGeneration` /
//! `ResumeScore`. A preset is a saved résumé (typed or uploaded); a
//! generation is one "tailor this against that JD" run, keeping a snapshot of
//! the inputs plus before/after scores so the history can show a score delta.

use serde::{Deserialize, Serialize};

use crate::store::{self, new_id, now_secs};

const PRESETS_FILE: &str = "resumes.json";
const GENERATIONS_FILE: &str = "resume-generations.json";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ResumePreset {
    pub id: u64,
    pub name: String,
    pub content: String,
    /// Original filename when uploaded (e.g. `Alex_Carter.docx`), so a saved
    /// output can reuse the name the user recognises.
    pub original_filename: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
}

/// Result of scoring a résumé against a JD, parsed from the strict plain-text
/// reply the model is asked for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ResumeScore {
    pub score: i32,
    pub verdict: String,
    pub missing: Vec<String>,
    pub strengths: Vec<String>,
}

impl ResumeScore {
    /// Parse the `SCORE:` / `VERDICT:` / `MISSING_KEYWORDS:` / `STRENGTHS:`
    /// block. Unknown lines are ignored so a chatty model still scores.
    pub fn parse(raw: &str) -> ResumeScore {
        let mut out = ResumeScore::default();
        for line in raw.lines() {
            let line = line.trim();
            let lower = line.to_ascii_uppercase();
            if let Some(v) = strip_prefix_ci(line, &lower, "SCORE:") {
                // Tolerate "82", "82/100", "82 points".
                let digits: String = v.chars().take_while(|c| c.is_ascii_digit()).collect();
                out.score = digits.parse().unwrap_or(0);
            } else if let Some(v) = strip_prefix_ci(line, &lower, "VERDICT:") {
                out.verdict = v.trim().to_string();
            } else if let Some(v) = strip_prefix_ci(line, &lower, "MISSING_KEYWORDS:") {
                out.missing = split_list(v);
            } else if let Some(v) = strip_prefix_ci(line, &lower, "STRENGTHS:") {
                out.strengths = split_list(v);
            }
        }
        out
    }

    /// Bucket used for the score color: good / fair / poor.
    pub fn band(&self) -> ScoreBand {
        if self.score >= 80 {
            ScoreBand::Good
        } else if self.score >= 60 {
            ScoreBand::Fair
        } else {
            ScoreBand::Poor
        }
    }

    pub fn recommendation(&self) -> &'static str {
        match self.band() {
            ScoreBand::Good => "Good match — safe to apply as-is",
            ScoreBand::Fair => "Decent match — minor tweaks recommended",
            ScoreBand::Poor => "Low match — tailor your résumé before applying",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScoreBand {
    Good,
    Fair,
    Poor,
}

fn strip_prefix_ci<'a>(line: &'a str, upper: &str, prefix: &str) -> Option<&'a str> {
    upper.starts_with(prefix).then(|| line[prefix.len()..].trim())
}

fn split_list(v: &str) -> Vec<String> {
    // Models sometimes wrap the list in brackets — strip those too.
    v.trim_matches(|c| c == '[' || c == ']')
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// One tailoring run: inputs, output, and before/after scores.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ResumeGeneration {
    pub id: u64,
    pub base_preset_id: u64,
    /// Snapshot of the base résumé, so the diff stays right if the preset is
    /// edited later.
    pub base_text: String,
    pub jd: String,
    pub generated_text: String,
    pub before_score: Option<ResumeScore>,
    pub after_score: Option<ResumeScore>,
    pub created_at: u64,
    pub updated_at: u64,
}

impl ResumeGeneration {
    /// First non-empty line of the JD, else a stamped fallback — history rows
    /// are never unlabelled.
    pub fn display_title(&self) -> String {
        match self.jd.lines().map(str::trim).find(|l| !l.is_empty()) {
            Some(line) => line.chars().take(60).collect(),
            None => format!("Generation #{}", self.id % 10_000),
        }
    }

    /// Points gained between the before and after scores.
    pub fn score_delta(&self) -> Option<i32> {
        Some(self.after_score.as_ref()?.score - self.before_score.as_ref()?.score)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct ResumeStore {
    pub presets: Vec<ResumePreset>,
    pub active_id: Option<u64>,
    /// Most-recent first.
    pub generations: Vec<ResumeGeneration>,
    /// Directory the two library files live in. Empty for a detached store
    /// (tests), which then never writes to disk.
    #[serde(skip)]
    dir: std::path::PathBuf,
}

impl ResumeStore {
    pub fn load() -> Self {
        let mut s = ResumeStore {
            presets: store::load(&store::library_path(PRESETS_FILE)),
            generations: store::load(&store::library_path(GENERATIONS_FILE)),
            active_id: None,
            dir: store::config_dir(),
        };
        // Selection lives in the presets file's sibling field on macOS; here
        // we simply default to the first résumé so the Build tab is never
        // pointing at nothing.
        s.active_id = s.presets.first().map(|p| p.id);
        s
    }

    pub fn save_presets(&self) {
        if self.dir.as_os_str().is_empty() {
            return; // detached store — nothing to write
        }
        let _ = store::save(&self.dir.join(PRESETS_FILE), &self.presets);
    }

    pub fn save_generations(&self) {
        if self.dir.as_os_str().is_empty() {
            return;
        }
        let _ = store::save(&self.dir.join(GENERATIONS_FILE), &self.generations);
    }

    // ── Présets ─────────────────────────────────────────────────────────────

    pub fn active(&self) -> Option<&ResumePreset> {
        let id = self.active_id?;
        self.presets.iter().find(|p| p.id == id)
    }

    pub fn active_text(&self) -> String {
        self.active().map(|p| p.content.clone()).unwrap_or_default()
    }

    pub fn add(&mut self, name: &str, content: &str, original_filename: Option<String>) -> u64 {
        let id = new_id();
        self.presets.push(ResumePreset {
            id,
            name: name.trim().to_string(),
            content: content.to_string(),
            original_filename,
            created_at: now_secs(),
            updated_at: now_secs(),
        });
        self.active_id = Some(id);
        self.save_presets();
        id
    }

    pub fn update_content(&mut self, id: u64, content: &str) {
        if let Some(p) = self.presets.iter_mut().find(|p| p.id == id) {
            p.content = content.to_string();
            p.updated_at = now_secs();
        }
        self.save_presets();
    }

    pub fn rename(&mut self, id: u64, name: &str) {
        if let Some(p) = self.presets.iter_mut().find(|p| p.id == id) {
            p.name = name.trim().to_string();
            p.updated_at = now_secs();
        }
        self.save_presets();
    }

    pub fn delete(&mut self, id: u64) {
        self.presets.retain(|p| p.id != id);
        if self.active_id == Some(id) {
            self.active_id = self.presets.first().map(|p| p.id);
        }
        self.save_presets();
    }

    // ── Generations ─────────────────────────────────────────────────────────

    pub fn add_generation(&mut self, base_preset_id: u64, base_text: &str, jd: &str) -> u64 {
        let id = new_id();
        self.generations.insert(
            0,
            ResumeGeneration {
                id,
                base_preset_id,
                base_text: base_text.to_string(),
                jd: jd.to_string(),
                generated_text: String::new(),
                before_score: None,
                after_score: None,
                created_at: now_secs(),
                updated_at: now_secs(),
            },
        );
        id
    }

    pub fn generation_mut(&mut self, id: u64) -> Option<&mut ResumeGeneration> {
        self.generations.iter_mut().find(|g| g.id == id)
    }

    pub fn generation(&self, id: u64) -> Option<&ResumeGeneration> {
        self.generations.iter().find(|g| g.id == id)
    }

    pub fn delete_generation(&mut self, id: u64) {
        self.generations.retain(|g| g.id != id);
        self.save_generations();
    }

    pub fn clear_generations(&mut self) {
        self.generations.clear();
        self.save_generations();
    }
}

/// Prompt asking for the strict scoring block `ResumeScore::parse` reads.
pub fn scoring_user_prompt(resume: &str, jd: &str) -> String {
    format!(
        "Job Description:\n{jd}\n\nResume:\n{resume}\n\n\
Analyse how well this resume matches the job description. Respond with ONLY this exact format (no other text):\n\
SCORE: [0-100]\n\
VERDICT: [one short sentence]\n\
MISSING_KEYWORDS: [comma-separated list of up to 6 important keywords from the JD not in the resume]\n\
STRENGTHS: [comma-separated list of up to 4 matching strengths]"
    )
}

/// Default system prompt for scoring (overridable by a `ResumeScoring` preset).
pub const DEFAULT_SCORING_PROMPT: &str =
    "You are a precise ATS (applicant tracking system) résumé screener. You compare a résumé \
against a job description and report a calibrated match score. Be honest and specific — a \
generous score helps nobody. Reply in the exact requested format with no extra commentary.";

/// Default system prompt for tailoring (overridable by a `ResumeGeneration`
/// preset). Mirrors the macOS generator's honesty rules: reframe what's really
/// there, never invent experience.
pub const DEFAULT_GENERATION_PROMPT: &str =
    "You are an expert résumé writer. Tailor the candidate's résumé to the job description.\n\n\
STAY TRUTHFUL. Reshape, reorder, and re-emphasize the experience that is actually in the \
résumé, and use the job description's vocabulary for it. Never invent employers, titles, \
dates, degrees, certifications, technologies, or metrics that aren't already there — \
reframing what exists is required, adding what doesn't is forbidden.\n\n\
COVER THE WHOLE RÉSUMÉ. Rewrite the summary, and tailor experience bullets across EVERY \
employer — editing only the summary and the skills list is a failure, because the experience \
bullets are where a recruiter actually looks.\n\n\
Output the full tailored résumé in clean markdown, preserving the original section order and \
structure. Then add a short \"## Key changes\" list explaining what you adjusted and why, and \
a \"## Missing keywords\" list of JD terms you could not honestly work in.";

/// User prompt for one tailoring run.
pub fn generation_user_prompt(resume: &str, jd: &str) -> String {
    let jd = if jd.trim().is_empty() { "(none provided — general polish)" } else { jd };
    format!("RÉSUMÉ:\n{resume}\n\nJOB DESCRIPTION:\n{jd}\n\nTailor the résumé to this role.")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_strict_score_block() {
        let raw = "SCORE: 82\n\
                   VERDICT: Strong match, minimal tailoring needed\n\
                   MISSING_KEYWORDS: Kubernetes, gRPC, Terraform\n\
                   STRENGTHS: Rust, distributed systems, payments";
        let s = ResumeScore::parse(raw);
        assert_eq!(s.score, 82);
        assert_eq!(s.verdict, "Strong match, minimal tailoring needed");
        assert_eq!(s.missing, vec!["Kubernetes", "gRPC", "Terraform"]);
        assert_eq!(s.strengths.len(), 3);
        assert_eq!(s.band(), ScoreBand::Good);
    }

    #[test]
    fn tolerates_sloppy_model_output() {
        // Bracketed lists, a "/100" suffix, and surrounding chatter.
        let raw = "Here you go!\nSCORE: 64/100\nVERDICT: Decent\nMISSING_KEYWORDS: [Go, Kafka]\n";
        let s = ResumeScore::parse(raw);
        assert_eq!(s.score, 64);
        assert_eq!(s.missing, vec!["Go", "Kafka"]);
        assert_eq!(s.band(), ScoreBand::Fair);
        assert!(s.strengths.is_empty());
    }

    #[test]
    fn unparseable_reply_scores_zero_rather_than_panicking() {
        let s = ResumeScore::parse("I can't help with that.");
        assert_eq!(s.score, 0);
        assert_eq!(s.band(), ScoreBand::Poor);
    }

    #[test]
    fn generation_title_uses_first_jd_line() {
        let g = ResumeGeneration {
            jd: "\n  Staff Engineer, Payments  \nOwn reliability…".into(),
            ..Default::default()
        };
        assert_eq!(g.display_title(), "Staff Engineer, Payments");
    }

    #[test]
    fn score_delta_needs_both_sides() {
        let mut g = ResumeGeneration {
            before_score: Some(ResumeScore { score: 61, ..Default::default() }),
            ..Default::default()
        };
        assert_eq!(g.score_delta(), None);
        g.after_score = Some(ResumeScore { score: 88, ..Default::default() });
        assert_eq!(g.score_delta(), Some(27));
    }

    #[test]
    fn deleting_active_preset_reselects() {
        let mut s = ResumeStore::default();
        let a = s.add("A", "resume a", None);
        let b = s.add("B", "resume b", None);
        assert_eq!(s.active_id, Some(b));
        s.delete(b);
        assert_eq!(s.active_id, Some(a), "deleting the active résumé selects another");
        s.delete(a);
        assert_eq!(s.active_id, None);
    }

    #[test]
    fn generations_are_newest_first() {
        let mut s = ResumeStore::default();
        let first = s.add_generation(1, "base", "jd one");
        let second = s.add_generation(1, "base", "jd two");
        assert_eq!(s.generations[0].id, second);
        assert_eq!(s.generations[1].id, first);
    }
}
