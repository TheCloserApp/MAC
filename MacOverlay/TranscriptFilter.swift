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

    /// Pure backchannel — what a listener says to show they're following,
    /// never a request for information. A segment made ENTIRELY of these
    /// (plus fillers) is an acknowledgement, not a question, no matter how
    /// long: "okay, right, yeah, that makes sense".
    private static let acknowledgments: Set<String> = [
        "ok", "okay", "kay", "yeah", "yea", "yes", "yep", "yup", "right",
        "sure", "correct", "exactly", "true", "fine", "good", "great",
        "nice", "cool", "perfect", "awesome", "excellent", "wonderful",
        "interesting", "wow", "gotcha", "understood", "understand",
        "makes", "sense", "sounds", "sound", "got", "get", "see", "i",
        "that", "it", "this", "thanks", "thank", "you", "alright",
        "all", "well", "no", "nope", "not", "really", "totally",
        "absolutely", "definitely", "certainly", "indeed", "cheers",
        "wait", "hold", "on", "one", "sec", "second", "moment", "just",
        "let", "me", "think", "hang", "and", "so", "but", "then", "now",
        "of", "course", "for", "your", "time", "a", "the", "is", "was",
    ]

    /// Words that, leading a segment, mark it as a question even without a
    /// question mark — the engine often drops terminal punctuation.
    private static let interrogativeLeads: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose",
        "which",
        // Yes/no question auxiliaries.
        "can", "could", "would", "will", "do", "does", "did", "is", "are",
        "was", "were", "have", "has", "had", "should", "shall", "may",
        "might", "am",
    ]

    /// Imperative openers that request an answer just as much as a
    /// question does — the classic interview prompt shape ("tell me
    /// about…", "walk me through…").
    private static let requestLeads: Set<String> = [
        "tell", "walk", "explain", "describe", "share", "discuss",
        "elaborate", "compare", "define", "list", "name", "imagine",
        "suppose", "consider", "outline", "summarize", "summarise",
        "pitch", "sell", "teach",
    ]

    /// Whether a transcript segment looks like something the candidate
    /// actually has to answer.
    enum ResponseVerdict {
        /// Clear question / request → send now, no model call.
        case yes
        /// Clear acknowledgement or fragment → don't send.
        case no
        /// Genuinely ambiguous; worth asking a small model. Kept
        /// deliberately narrow — every `.unsure` costs a round-trip on the
        /// critical path.
        case unsure
    }

    /// Local, instant triage of "does this need an answer?". Deciding the
    /// obvious cases here is what keeps auto-send fast: real questions go
    /// straight through, backchannel is dropped for free, and only the
    /// murky middle pays for a model call.
    ///
    /// Ordering matters — a segment with a question mark is a question even
    /// if it also contains acknowledgement words ("okay, so what's next?").
    static func warrantsResponse(_ raw: String) -> ResponseVerdict {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .no }
        let words = tokenize(t).filter { !fillers.contains($0) }
        guard !words.isEmpty else { return .no }

        // The engine heard an actual question.
        if t.contains("?") { return .yes }

        // Nothing but backchannel — "okay", "yeah that makes sense",
        // "right, got it", "hold on one second".
        if words.allSatisfy({ acknowledgments.contains($0) }) { return .no }

        // Question / request shape.
        if let first = words.first,
           interrogativeLeads.contains(first) || requestLeads.contains(first) {
            return .yes
        }

        // Long enough to be a substantive prompt. Interviewers routinely
        // pose scenarios as statements ("So your team is on call and the
        // pager goes off at 3am and the database is down").
        if words.count >= 8 { return .yes }

        // Short, unpunctuated, no question shape — a fragment or an aside.
        if words.count < 4 { return .no }

        return .unsure
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

    // NOTE: Echo suppression (dropping segments that read back the last
    // answer) was removed deliberately. Real use runs the mic on System
    // audio (interviewer only — nothing to echo), and during mic testing the
    // user's own follow-up questions must transcribe and send. Noise/filler
    // is still filtered by `isMeaningful`. If a read-back problem resurfaces
    // for mic/mic+system setups, restore it from git history.

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
