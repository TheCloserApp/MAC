//! Heuristics for deciding whether a transcription segment is real speech
//! worth sending to the AI, versus background noise / filler the speech engine
//! hallucinated. Drives the auto-send and pause flows so they don't fire on
//! "um", coughs, `[noise]` markers, or stray single characters.
//!
//! Direct port of `TranscriptFilter.swift`. Only gates what gets *sent* —
//! partial transcripts are still shown live in the strip.

/// Non-lexical filler / hesitation tokens. A segment made up only of these
/// (plus punctuation) carries no content and is treated as noise.
const FILLERS: &[&str] = &[
    "uh", "uhh", "uhm", "um", "umm", "ummm", "hmm", "hmmm", "hm", "mm", "mmm",
    "mhm", "mhmm", "huh", "ah", "ahh", "aah", "er", "err", "eh", "ehh", "oh",
    "ohh", "uhhuh", "mmhmm",
];

/// Words that, when a segment ENDS on them without terminal punctuation,
/// strongly imply the speaker is mid-thought. Used by [`seems_complete`].
const DANGLING_CONNECTIVES: &[&str] = &[
    "and", "or", "but", "so", "because", "with", "without", "to", "of", "the",
    "a", "an", "for", "in", "on", "at", "about", "into", "from", "is", "are",
    "was", "were", "be", "been", "being", "if", "when", "while", "that",
    "which", "who", "whose", "how", "what", "why", "where", "your", "my",
    "their", "our", "his", "her", "its", "like", "than", "as", "versus", "vs",
    "can", "could", "would", "should", "will", "do", "does", "did", "have",
    "has", "had", "not", "very", "more", "most", "some", "any",
];

/// Stateless transcript heuristics. A zero-sized namespace mirroring the Swift
/// `enum TranscriptFilter`.
pub struct TranscriptFilter;

impl TranscriptFilter {
    /// Tokenise into lowercase alphanumeric words, stripping all punctuation.
    fn tokenize(raw: &str) -> Vec<String> {
        raw.split(|c: char| !c.is_alphanumeric())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_lowercase())
            .collect()
    }

    /// Does this transcript read like a finished thought? Drives the auto-send
    /// grace window — terminal punctuation sends almost immediately; trailing
    /// off mid-sentence waits longer.
    ///
    /// * Ends with `?` / `.` / `!` → complete. Trailing `…` / `...` → NOT.
    /// * Ends on a dangling connective ("with", "and", "how") → incomplete.
    /// * Otherwise (no punctuation, neutral last word) → complete.
    pub fn seems_complete(raw: &str) -> bool {
        let t = raw.trim();
        if t.is_empty() {
            return false;
        }
        if t.ends_with("...") || t.ends_with('\u{2026}') {
            return false;
        }
        if t.ends_with('?') || t.ends_with('.') || t.ends_with('!') {
            return true;
        }
        if t.ends_with(',')
            || t.ends_with(';')
            || t.ends_with(':')
            || t.ends_with('-')
            || t.ends_with('\u{2013}')
            || t.ends_with('\u{2014}')
        {
            return false;
        }
        let last_word = Self::tokenize(t).pop().unwrap_or_default();
        !DANGLING_CONNECTIVES.contains(&last_word.as_str())
    }

    /// Canonical form for change detection: lowercase alphanumeric words joined
    /// by single spaces. Lets the silence/auto-send clocks ignore cosmetic
    /// punctuation/casing revisions the engine makes after the speaker stops.
    pub fn normalized(raw: &str) -> String {
        Self::tokenize(raw).join(" ")
    }

    /// True when `raw` contains at least some real spoken content. False for
    /// empty/whitespace, non-speech annotations (`[noise]`, `(music)`,
    /// `[BLANK_AUDIO]`), filler-only utterances, and segments with fewer than
    /// two letters of real content.
    pub fn is_meaningful(raw: &str) -> bool {
        // Drop bracketed / parenthesised non-speech annotations.
        let without_annotations = strip_brackets(raw);

        let words = Self::tokenize(&without_annotations);
        let real_words: Vec<&String> =
            words.iter().filter(|w| !FILLERS.contains(&w.as_str())).collect();
        if real_words.is_empty() {
            return false;
        }
        // Require >= 2 alphanumeric chars of real content.
        let real_char_count: usize = real_words.iter().map(|w| w.chars().count()).sum();
        real_char_count >= 2
    }
}

/// Replace `[...]` and `(...)` spans with a space — the regex
/// `\[[^\]]*\]|\([^\)]*\)` from the Swift original, hand-rolled to avoid a
/// regex dependency.
fn strip_brackets(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut depth_square = 0u32;
    let mut depth_round = 0u32;
    for c in raw.chars() {
        match c {
            '[' => {
                depth_square += 1;
                out.push(' ');
            }
            ']' => {
                depth_square = depth_square.saturating_sub(1);
                out.push(' ');
            }
            '(' => {
                depth_round += 1;
                out.push(' ');
            }
            ')' => {
                depth_round = depth_round.saturating_sub(1);
                out.push(' ');
            }
            _ if depth_square > 0 || depth_round > 0 => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::TranscriptFilter as F;

    #[test]
    fn meaningful_rejects_noise_and_filler() {
        assert!(!F::is_meaningful(""));
        assert!(!F::is_meaningful("   "));
        assert!(!F::is_meaningful("[noise]"));
        assert!(!F::is_meaningful("(music)"));
        assert!(!F::is_meaningful("[BLANK_AUDIO]"));
        assert!(!F::is_meaningful("um, uh... hmm"));
        assert!(!F::is_meaningful("a")); // single stray letter
    }

    #[test]
    fn meaningful_accepts_real_speech() {
        assert!(F::is_meaningful("Tell me about yourself."));
        assert!(F::is_meaningful("um, what is a closure?")); // filler + content
        assert!(F::is_meaningful("[crosstalk] so why React?")); // annotation + content
    }

    #[test]
    fn seems_complete_on_terminal_punctuation() {
        assert!(F::seems_complete("What is your greatest weakness?"));
        assert!(F::seems_complete("Walk me through your last project."));
        assert!(F::seems_complete("Got it!"));
    }

    #[test]
    fn seems_incomplete_when_trailing_off() {
        assert!(!F::seems_complete("Tell me about your experience with"));
        assert!(!F::seems_complete("and then we were"));
        assert!(!F::seems_complete("so the thing is,"));
        assert!(!F::seems_complete("well..."));
        assert!(!F::seems_complete("hmm\u{2026}"));
    }

    #[test]
    fn seems_complete_on_neutral_unpunctuated_tail() {
        // No punctuation, last word isn't a connective → treat as complete so
        // unpunctuated engines don't stall every send.
        assert!(F::seems_complete("describe a hard bug you fixed recently"));
    }

    #[test]
    fn normalized_ignores_cosmetic_revisions() {
        assert_eq!(F::normalized("So, tell me."), F::normalized("so tell me"));
        assert_eq!(F::normalized("React?!"), "react");
    }
}
