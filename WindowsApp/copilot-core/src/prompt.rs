//! Prompt assembly: fill the `{NAME}`/`{ROLE}`/`{COMPANY}` markers in a mode's
//! system prompt, and turn free-text context (résumé / JD / notes) into the
//! conversation anchor.
//!
//! Mirrors `AIController.resolveActivePrompt` and the macOS "context as the
//! first history pair" pattern that keeps answers grounded in the user's real
//! material.

use crate::prompts::{PromptKind, PromptStore};
use crate::settings::Settings;

/// A named block of extracted text riding along as session context — the
/// uploaded résumé, or any attached JD / notes file.
#[derive(Debug, Clone)]
pub struct Attachment {
    pub name: String,
    pub text: String,
}

/// Substitute the profile markers into a raw system prompt, applying the same
/// fallbacks the macOS app used ("the user" / "a professional" / "their
/// company") so the sentence always reads naturally.
pub fn resolve_system_prompt(raw: &str, settings: &Settings) -> String {
    let name = non_empty_or(&settings.user_name, "the user");
    // Fallback fits the "is a {ROLE}" template grammar (no leading article).
    let role = non_empty_or(&settings.user_role, "professional");
    let company = non_empty_or(&settings.user_company, "their company");
    raw.replace("{NAME}", name)
        .replace("{ROLE}", role)
        .replace("{COMPANY}", company)
}

/// The full system prompt for the active mode, with markers resolved.
pub fn system_prompt_for(settings: &Settings) -> String {
    resolve_system_prompt(settings.session_mode.system_prompt(), settings)
}

/// The session system prompt, honoring a saved preset when one is active.
///
/// Mirrors `AIController.resolveActivePrompt`: an explicitly-activated
/// conversation preset wins; otherwise the preset the user linked to this
/// mode; otherwise the built-in mode prompt. Markers are resolved either way,
/// so a custom prompt can use `{NAME}` / `{ROLE}` / `{COMPANY}` too.
pub fn session_system_prompt(settings: &Settings, prompts: &PromptStore) -> String {
    let raw = prompts
        .active(PromptKind::Conversation)
        .or_else(|| prompts.linked(settings.session_mode))
        .map(|p| p.content.clone())
        .unwrap_or_else(|| settings.session_mode.system_prompt().to_string());
    resolve_system_prompt(&raw, settings)
}

/// Build the leading conversation anchor from the user's context blob. Returns
/// an empty vec when there's no context. The anchor is a single
/// (user, assistant) pair so it sits at the front of `history`, exactly where
/// the macOS app placed its résumé/JD attachments for prompt-cache stability.
pub fn context_anchor(settings: &Settings) -> Vec<(String, String)> {
    context_anchor_with(settings, &[])
}

/// The anchor, plus any attached files (résumé, JD, notes) as labelled blocks.
///
/// Everything goes in one pair rather than several so the prefix stays byte-
/// stable across turns and the providers' prompt caches keep hitting.
pub fn context_anchor_with(settings: &Settings, attachments: &[Attachment]) -> Vec<(String, String)> {
    let ctx = settings.context.trim();
    let attachments: Vec<&Attachment> = attachments.iter().filter(|a| !a.text.trim().is_empty()).collect();
    if ctx.is_empty() && attachments.is_empty() {
        return Vec::new();
    }
    let mut user = String::from(
        "Here is my background and context for this session. Use it to ground every \
answer in my real experience, projects, and the role I'm interviewing for. Do not \
invent details that aren't here.",
    );
    if !ctx.is_empty() {
        user.push_str("\n\n");
        user.push_str(ctx);
    }
    for a in attachments {
        user.push_str(&format!("\n\n--- {} ---\n{}", a.name.trim(), a.text.trim()));
    }
    let assistant =
        "Understood. I'll ground my answers in your background and the role, and keep them \
tight and ready to say out loud."
            .to_string();
    vec![(user, assistant)]
}

fn non_empty_or<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.trim().is_empty() {
        fallback
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::modes::SessionMode;

    #[test]
    fn substitutes_profile_markers() {
        let s = Settings {
            session_mode: SessionMode::Interview,
            user_name: "Ada Lovelace".into(),
            user_role: "Senior Engineer".into(),
            user_company: "Analytical Co".into(),
            ..Default::default()
        };
        let p = system_prompt_for(&s);
        assert!(p.contains("Ada Lovelace is a Senior Engineer at Analytical Co."));
        assert!(!p.contains("{NAME}"));
        assert!(!p.contains("{ROLE}"));
        assert!(!p.contains("{COMPANY}"));
    }

    #[test]
    fn falls_back_when_profile_blank() {
        let s = Settings { session_mode: SessionMode::Interview, ..Default::default() };
        let p = system_prompt_for(&s);
        assert!(p.contains("the user is a professional at their company."));
    }

    #[test]
    fn context_anchor_present_only_with_context() {
        let mut s = Settings::default();
        assert!(context_anchor(&s).is_empty());
        s.context = "5 years building payments at Stripe.".into();
        let anchor = context_anchor(&s);
        assert_eq!(anchor.len(), 1);
        assert!(anchor[0].0.contains("payments at Stripe"));
    }

    #[test]
    fn attachments_ride_in_the_same_anchor_pair() {
        let s = Settings::default();
        let files = [
            Attachment { name: "resume.docx".into(), text: "Alex Carter — Rust".into() },
            Attachment { name: "jd.pdf".into(), text: "Staff Engineer, Payments".into() },
            // Empty attachments must not create an anchor of their own.
            Attachment { name: "blank.txt".into(), text: "   ".into() },
        ];
        let anchor = context_anchor_with(&s, &files);
        assert_eq!(anchor.len(), 1, "one pair keeps the cached prefix stable");
        let body = &anchor[0].0;
        assert!(body.contains("--- resume.docx ---"));
        assert!(body.contains("Staff Engineer, Payments"));
        assert!(!body.contains("blank.txt"));
    }

    #[test]
    fn active_preset_overrides_the_mode_prompt() {
        use crate::prompts::{PromptKind, PromptStore};
        let s = Settings {
            session_mode: SessionMode::Interview,
            user_name: "Ada".into(),
            ..Default::default()
        };
        let mut store = PromptStore::default();
        let id = store.add("Terse", "Answer as {NAME}, one line only.", PromptKind::Conversation);
        store.active_id = Some(id);

        let p = session_system_prompt(&s, &store);
        assert_eq!(p, "Answer as Ada, one line only.");
    }

    #[test]
    fn falls_back_to_linked_then_builtin_prompt() {
        let s = Settings { session_mode: SessionMode::Meeting, ..Default::default() };
        let mut store = PromptStore::default();

        // Nothing saved at all → the built-in mode prompt.
        let builtin = session_system_prompt(&s, &store);
        assert!(builtin.contains("real-time meeting assistant"));

        // A preset linked to this mode is used without being "activated".
        let id = store.add("Meeting rules", "Only list action items.", PromptKind::Conversation);
        store.presets.iter_mut().find(|p| p.id == id).unwrap().linked_mode = Some(SessionMode::Meeting);
        assert_eq!(session_system_prompt(&s, &store), "Only list action items.");
    }
}
