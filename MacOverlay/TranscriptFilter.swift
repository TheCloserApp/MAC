import Foundation

/// Heuristics for deciding whether a transcription segment is real speech
/// worth sending to the AI, versus background noise / filler the speech
/// engine hallucinated. Used to keep the auto-generate, VAD, and pause
/// flows from firing on "um", coughs, `[noise]` markers, or stray single
/// characters.
///
/// This only gates what gets *sent* — partial transcripts are still shown
/// live in the strip so the user sees everything that's being heard.
enum TranscriptFilter {

    /// Non-lexical filler / hesitation tokens. A segment made up only of
    /// these (plus punctuation) carries no content and is treated as noise.
    private static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "um", "umm", "ummm", "hmm", "hmmm", "hm",
        "mm", "mmm", "mhm", "mhmm", "huh", "ah", "ahh", "aah", "er", "err",
        "eh", "ehh", "oh", "ohh", "uhhuh", "mmhmm"
    ]

    /// Words that, when a segment ENDS on them without terminal
    /// punctuation, strongly imply the speaker is mid-thought ("tell me
    /// about your experience with…", "and then we…"). Used by
    /// `seemsComplete` to pick a longer grace window before auto-sending.
    private static let danglingConnectives: Set<String> = [
        "and", "or", "but", "so", "because", "with", "without", "to", "of",
        "the", "a", "an", "for", "in", "on", "at", "about", "into", "from",
        "is", "are", "was", "were", "be", "been", "being",
        "if", "when", "while", "that", "which", "who", "whose",
        "how", "what", "why", "where",
        "your", "my", "their", "our", "his", "her", "its",
        "like", "than", "as", "versus", "vs",
        "can", "could", "would", "should", "will", "do", "does", "did",
        "have", "has", "had", "not", "very", "more", "most", "some", "any"
    ]

    /// Heuristic: does this transcript read like a finished thought?
    /// Drives the auto-send grace window — a segment that ends with
    /// terminal punctuation sends almost immediately, one that trails
    /// off mid-sentence waits longer for the speaker to continue.
    ///
    /// - Ends with `?` / `.` / `!` → complete (engines emit punctuation).
    ///   Trailing `…` / `...` means trailing off, NOT complete.
    /// - Ends on a dangling connective ("with", "and", "how") → incomplete.
    /// - Anything else (no punctuation, neutral last word) → treated as
    ///   complete so unpunctuated engines don't stall every send.
    static func seemsComplete(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("...") || t.hasSuffix("…") { return false }
        if t.hasSuffix("?") || t.hasSuffix(".") || t.hasSuffix("!") { return true }
        if t.hasSuffix(",") || t.hasSuffix(";") || t.hasSuffix(":")
            || t.hasSuffix("-") || t.hasSuffix("–") || t.hasSuffix("—") {
            return false
        }
        let lastWord = t.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .last ?? ""
        return !danglingConnectives.contains(lastWord)
    }

    /// Canonical form of a transcript for change detection: lowercase
    /// alphanumeric words joined by single spaces. Speech engines revise
    /// punctuation and capitalization AFTER the speaker has stopped
    /// ("so tell me" → "So, tell me") — comparing normalized forms lets
    /// the silence/auto-send clocks ignore those cosmetic revisions
    /// instead of restarting on every one, which randomly delayed sends.
    static func normalized(_ raw: String) -> String {
        tokenize(raw).joined(separator: " ")
    }

    /// True when `segment` is mostly made of words from `answer` — the
    /// signature of the user reading the assistant's reply out loud into
    /// their own microphone. Without this check, auto-mode transcribes the
    /// read-back, treats it as a new question, and answers it — generating
    /// 3+ answers per real question in mic / mic+system setups.
    ///
    /// Heuristic: take the segment's significant words (≥3 letters, not
    /// filler); if ≥75% of them appear in the answer, it's a read-back.
    /// Real follow-up questions bring new vocabulary, so they pass.
    static func echoesAnswer(_ segment: String, answer: String) -> Bool {
        guard !answer.isEmpty else { return false }
        // A segment the engine punctuated as a QUESTION is almost never a
        // read-back (answers are statements). Follow-ups that quote the
        // answer's own vocabulary ("can you expand on the canary rollout
        // part?") used to be silently dropped here — the interviewer asked,
        // and nothing happened.
        if segment.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            return false
        }
        let segWords = tokenize(segment).filter { $0.count >= 3 && !fillers.contains($0) }
        // Too few significant words to judge — let isMeaningful decide.
        guard segWords.count >= 4 else { return false }
        let answerSet = Set(tokenize(answer))
        let hits = segWords.filter { answerSet.contains($0) }.count
        return Double(hits) / Double(segWords.count) >= 0.75
    }

    private static func tokenize(_ raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when `raw` contains at least some real spoken content. Returns
    /// false for empty / whitespace-only input, non-speech annotations
    /// (`[noise]`, `(music)`, `[BLANK_AUDIO]`), filler-only utterances, and
    /// segments with fewer than two letters of real content.
    static func isMeaningful(_ raw: String) -> Bool {
        // Drop bracketed / parenthesised non-speech annotations that engines
        // emit for noise, music, or blank audio.
        let withoutAnnotations = raw.replacingOccurrences(
            of: "\\[[^\\]]*\\]|\\([^\\)]*\\)",
            with: " ",
            options: .regularExpression
        )

        // Tokenise into lowercase alphanumeric words, stripping punctuation.
        let words = withoutAnnotations
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Keep only words that aren't pure filler.
        let realWords = words.filter { !fillers.contains($0) }
        guard !realWords.isEmpty else { return false }

        // Require at least two alphanumeric characters of real content so a
        // single stray letter from noise ("a", "s") doesn't count as speech.
        let realCharCount = realWords.reduce(0) { $0 + $1.count }
        return realCharCount >= 2
    }
}
