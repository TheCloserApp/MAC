import Foundation
import AppKit

/// Tiny in-memory filesystem we expose to Claude's built-in `text_editor`
/// tool. We mount exactly one file — the resume's `word/document.xml` — at
/// a fixed virtual path, and route every `view` / `str_replace` / `insert`
/// command Claude issues against it. An actor keeps the state safe across
/// the async tool-call boundary.
private actor TextEditorFS {
    private let path: String
    private(set) var content: String
    private(set) var editCount: Int = 0
    /// Undo stack for `undo_edit`. Keep a few snapshots so Claude can back
    /// out a mistake without trashing the whole document.
    private var history: [String] = []
    private let historyLimit = 10
    /// Max lines returned when Claude calls `view` without a `view_range`.
    /// Full-file views blow past typical rate limits instantly (a typical
    /// docx is 30-50k tokens), so we return only the head and nudge Claude
    /// to use ranges for deeper reads.
    private let previewLineCap = 200

    init(path: String, initialContent: String) {
        self.path = path
        // DOCX's `document.xml` is usually a single mega-line with no
        // whitespace between tags. Pre-split it so Claude can use line-based
        // `view_range` / `str_replace` meaningfully. Inserting newlines only
        // between tags (after every `>` that's followed by `<`) is safe:
        // whitespace between XML tags is ignored by Word, and text runs
        // with `xml:space="preserve"` are left untouched because their
        // content doesn't contain `><`.
        self.content = initialContent.replacingOccurrences(of: "><", with: ">\n<")
    }

    // MARK: - text_editor commands

    /// `view` — return the current file (or a line range) with 1-indexed
    /// line numbers, cat -n style. The text_editor contract expects this.
    ///
    /// When no `view_range` is supplied, we deliberately truncate at
    /// `previewLineCap` lines and tell Claude to use `view_range` for more.
    /// Without this cap, the first view returns the whole ~30-50k-token
    /// document.xml and blows through the per-minute input token budget
    /// within a couple of turns.
    func view(path: String, range: [Int]?) -> String {
        guard path == self.path else {
            return "Error: \(path) not found. The only editable file is \(self.path)."
        }
        let lines = content.components(separatedBy: "\n")
        let totalLines = lines.count
        let start: Int
        var end: Int
        var truncated = false
        if let r = range, r.count >= 2 {
            start = max(1, r[0])
            end = (r[1] == -1) ? totalLines : min(totalLines, r[1])
            // Even with an explicit range, cap the chunk so a careless
            // `view_range: [1, -1]` doesn't flood the context either.
            if end - start + 1 > 600 {
                end = start + 599
                truncated = true
            }
        } else {
            start = 1
            end = min(totalLines, previewLineCap)
            if end < totalLines { truncated = true }
        }
        guard start <= end else { return "" }
        let slice = lines[(start - 1)..<end]
        var out = slice.enumerated().map { (i, line) in "\(start + i)\t\(line)" }
                      .joined(separator: "\n")
        if truncated {
            out += "\n\n[... \(totalLines) total lines in \(self.path). Showing \(start)-\(end). Use view_range with a specific window (e.g. [\(end + 1), \(min(totalLines, end + 200))]) to see more.]"
        }
        return out
    }

    /// `str_replace` — exact-match replacement. The text_editor contract
    /// requires `old_str` to occur exactly once; more than one match is
    /// rejected so Claude can disambiguate.
    func strReplace(path: String, old: String, new: String) -> String {
        guard path == self.path else { return "Error: \(path) not found." }
        guard !old.isEmpty else { return "Error: old_str cannot be empty." }
        let hits = content.components(separatedBy: old).count - 1
        if hits == 0 { return "Error: old_str not found verbatim in \(self.path). Re-view the region and copy the exact characters (including whitespace)." }
        if hits > 1 { return "Error: old_str matches \(hits) places. Add more surrounding context so it's unique." }
        pushHistory()
        content = content.replacingOccurrences(of: old, with: new)
        editCount += 1
        return "OK"
    }

    /// `insert` — add `new_str` at `insert_line` (0 = top of file).
    func insert(path: String, line: Int, text: String) -> String {
        guard path == self.path else { return "Error: \(path) not found." }
        var lines = content.components(separatedBy: "\n")
        let idx = max(0, min(lines.count, line))
        pushHistory()
        lines.insert(text, at: idx)
        content = lines.joined(separator: "\n")
        editCount += 1
        return "OK"
    }

    /// `create` — overwrite the file's content with `file_text`. We refuse
    /// to create new paths because we only mount one file.
    func create(path: String, text: String) -> String {
        guard path == self.path else { return "Error: cannot create \(path); only \(self.path) is writable." }
        pushHistory()
        content = text
        editCount += 1
        return "OK"
    }

    /// `undo_edit` — restore the most recent snapshot.
    func undoEdit(path: String) -> String {
        guard path == self.path else { return "Error: \(path) not found." }
        guard let prev = history.popLast() else { return "Error: nothing to undo." }
        content = prev
        editCount = max(0, editCount - 1)
        return "OK"
    }

    // MARK: - helpers

    private func pushHistory() {
        history.append(content)
        if history.count > historyLimit { history.removeFirst() }
    }
}

/// Structured JSON Claude returns in Fast mode. Fields are optional so a
/// partial response still decodes.
private struct GapAnalysis: Decodable {
    let gap_summary: String?
    let missing_keywords: [String]?
    let bullets_to_add: [BulletAddDTO]?
    let bullets_to_rewrite: [BulletRewriteDTO]?
}

private struct BulletAddDTO: Decodable {
    let employer: String
    let text: String
}

private struct BulletRewriteDTO: Decodable {
    let original: String
    let rewritten: String
}

/// Shape returned by Fast mode's index-based flow. `rewrites` and
/// `additions` reference paragraphs by their 1-based index in the numbered
/// list Claude is shown — eliminates the silent-no-match failure mode of
/// text-based matching.
private struct IndexedGapAnalysis: Decodable {
    let gap_summary: String?
    let missing_keywords: [String]?
    let rewrites: [IndexedRewriteDTO]?
    let additions: [IndexedAdditionDTO]?
}

private struct IndexedRewriteDTO: Decodable {
    let index: Int
    let new_text: String
}

private struct IndexedAdditionDTO: Decodable {
    let after_index: Int
    let new_text: String
}

/// Owns resume generation + ATS scoring + DOCX export. The VM still holds the
/// per-run state (resumeJD, resumeOutput, resumeScore, etc.) but all logic to
/// drive it lives here.
@MainActor
final class ResumeController {
    private weak var vm: OverlayViewModel?

    init(vm: OverlayViewModel) {
        self.vm = vm
    }

    // MARK: - Hybrid executor model selection

    /// Sticky preference for the Hybrid mode's Haiku executor. The default
    /// points at 4.5 because Anthropic hasn't shipped Haiku 4.6 yet (as of
    /// 2026-04). If/when it does, flip `preferredHaikuModel` to
    /// `"claude-haiku-4-6"`; the fallback path below will catch any gap
    /// between rollout and availability on individual accounts.
    private static var cachedHybridHaikuExecutor: String?
    private static let preferredHaikuModel = "claude-haiku-4-5-20251001"
    fileprivate static let fallbackHaikuModel = "claude-haiku-4-5-20251001"

    fileprivate static func preferredHaikuExecutorModel() -> String {
        cachedHybridHaikuExecutor ?? preferredHaikuModel
    }
    fileprivate static func recordHaikuExecutorSuccess(_ model: String) {
        cachedHybridHaikuExecutor = model
    }
    fileprivate static func recordHaikuExecutorFallback() {
        cachedHybridHaikuExecutor = fallbackHaikuModel
    }

    /// Does this error body look like Anthropic rejecting an unknown model?
    /// Anthropic's 404 shape is `{"error":{"type":"not_found_error",
    /// "message":"model: claude-…"}}` — we match that plus the usual 400-
    /// style "invalid model" phrasings so the fallback triggers either way.
    fileprivate static func looksLikeInvalidModel(status: Int, body: String) -> Bool {
        guard status == 400 || status == 404 else { return false }
        let b = body.lowercased()
        // Anthropic 404: "not_found_error" + model name in the message.
        if status == 404 && (b.contains("not_found_error") || b.contains("model:")) {
            return true
        }
        return b.contains("valid model")
            || b.contains("invalid model")
            || b.contains("model not found")
            || b.contains("does not exist")
            || b.contains("unknown model")
    }

    // MARK: - Score

    /// Score the active resume preset against the given JD. Updates
    /// `vm.resumeScore` when done; no-op if key or resume missing.
    func score(jd: String) {
        guard let vm else { return }
        let base = vm.currentResumeText
        guard !base.isEmpty, !vm.apiKey.isEmpty else { return }

        vm.resumeJD          = jd
        vm.resumeScore       = nil
        vm.isScoringResume   = true
        vm.showResumeBuilder = true

        let prompt = """
        Job Description:
        \(jd)

        Resume:
        \(base)

        Analyse how well this resume matches the job description. Respond with ONLY this exact format (no other text):
        SCORE: [0-100]
        VERDICT: [one short sentence — e.g. "Strong match, minimal tailoring needed" or "Significant gaps, customisation recommended"]
        MISSING_KEYWORDS: [comma-separated list of up to 6 important keywords from the JD not in the resume]
        STRENGTHS: [comma-separated list of up to 4 matching strengths]
        """

        let apiKeyCopy = vm.apiKey
        let openAIKeyCopy = vm.openAIApiKey
        let scoringSystemPrompt = vm.resumeScoringPromptResolved

        Task { [weak vm] in
            do {
                let raw = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey:       apiKeyCopy,
                    openAIApiKey: openAIKeyCopy,
                    model:        "claude-haiku-4-5-20251001",
                    screenshot:   nil,
                    systemPrompt: scoringSystemPrompt
                )
                vm?.resumeScore = ResumeScore(raw: raw)
            } catch {
                vm?.resumeScore = ResumeScore(
                    score: 0,
                    verdict: "Error: \(error.localizedDescription)",
                    missing: [],
                    strengths: []
                )
            }
            vm?.isScoringResume = false
        }
    }

    // MARK: - Generate

    /// Generate a tailored resume + save as DOCX. Requires a JD, an active
    /// resume preset, and an Anthropic key.
    ///
    /// Flow: pre-score base → generate → post-score output → save DOCX →
    /// record everything in a `ResumeGeneration` so the Resume panel can
    /// show the before/after diff and score delta.
    func generate() {
        guard let vm else { return }
        let base = vm.currentResumeText
        let basePreset = vm.resumeStore.activePreset
        guard !vm.resumeJD.isEmpty,
              !base.isEmpty,
              !vm.apiKey.isEmpty,
              let preset = basePreset else { return }

        vm.isGeneratingResume = true
        vm.resumeGenerationStatus = "Scoring your current résumé…"
        vm.resumeOutput       = ""
        vm.resumeFileURL      = nil

        let jd = vm.resumeJD

        // Seed the generation row at the top of history.
        let generation = vm.resumeStore.addGeneration(
            basePresetID: preset.id,
            baseText: base,
            jd: jd
        )
        let generationID = generation.id

        let apiKeyCopy = vm.apiKey
        let openAIKeyCopy = vm.openAIApiKey

        let scoringSystemPrompt = vm.resumeScoringPromptResolved
        let generationSystemPrompt = vm.resumeGenerationPromptResolved
        let generationModel = vm.resumeGenerationModel.rawValue
        let mode            = vm.resumeMode
        let skipScoring     = vm.resumeSkipScoring

        // Closure that pipes status lines from the generation flow into the
        // VM so the Resume panel can show live progress.
        let weakVM = self.vm
        let status: @Sendable (String) -> Void = { line in
            Task { @MainActor in weakVM?.resumeGenerationStatus = line }
        }

        Task { [weak self, weak vm] in
            guard let self else { return }

            // 1. Pre-score — optional. Skipped when the user has enabled
            //    scoring-skip (saves one Haiku call, ~25% of per-run cost).
            if !skipScoring {
                status("Scoring your current résumé…")
                let preScore = await self.scoreResume(base, jd: jd,
                                                      apiKey: apiKeyCopy,
                                                      openAIKey: openAIKeyCopy,
                                                      systemPrompt: scoringSystemPrompt)
                vm?.resumeScore = preScore
                if var g = vm?.resumeStore.generations.first(where: { $0.id == generationID }) {
                    g.beforeScore = preScore
                    vm?.resumeStore.updateGeneration(g)
                }
            }

            // 2. Generate tailored output.
            //    - FAST mode: single JSON call, Swift applies the edits.
            //      ~15× cheaper than the agent loop. Default.
            //    - QUALITY mode: text_editor agent loop with per-edit
            //      verification. Use when the user wants a final polish.
            //    - Plain-text fallback when no `originalDOCX` is available
            //      (imported from PDF/RTF/TXT).
            do {
                let result: String
                let changelog: String
                let url: URL
                if let originalBytes = preset.originalDOCX,
                   !base.isEmpty {
                    switch mode {
                    case .fast:
                        let (r, c, u) = try await self.generateViaFastMode(
                            originalBytes: originalBytes,
                            outputFilename: preset.originalFilename,
                            resumeText: base,
                            jd: jd,
                            model: generationModel,
                            apiKey: apiKeyCopy,
                            openAIKey: openAIKeyCopy,
                            systemPrompt: generationSystemPrompt,
                            onStatus: status
                        )
                        result = r; changelog = c; url = u
                    case .hybrid:
                        guard let xml = try? DOCXTemplateEditor.extractDocumentXML(from: originalBytes),
                              !xml.isEmpty else {
                            throw DOCXTemplateEditor.DOCXError.missingDocumentXML
                        }
                        let (r, c, u) = try await self.generateViaHybrid(
                            documentXML: xml,
                            originalBytes: originalBytes,
                            outputFilename: preset.originalFilename,
                            resumeText: base,
                            jd: jd,
                            apiKey: apiKeyCopy,
                            openAIKey: openAIKeyCopy,
                            systemPrompt: generationSystemPrompt,
                            onStatus: status
                        )
                        result = r; changelog = c; url = u
                    case .quality:
                        guard let xml = try? DOCXTemplateEditor.extractDocumentXML(from: originalBytes),
                              !xml.isEmpty else {
                            throw DOCXTemplateEditor.DOCXError.missingDocumentXML
                        }
                        let (r, c, u) = try await self.generateViaStrReplace(
                            documentXML: xml,
                            originalBytes: originalBytes,
                            outputFilename: preset.originalFilename,
                            jd: jd,
                            model: generationModel,
                            apiKey: apiKeyCopy,
                            openAIKey: openAIKeyCopy,
                            systemPrompt: generationSystemPrompt
                        )
                        result = r; changelog = c; url = u
                    }
                } else {
                    status("Rewriting résumé…")
                    let plainPrompt = Self.generationPrompt(jd: jd, base: base)
                    result = try await AIManager.shared.sendMessage(
                        plainPrompt,
                        apiKey:       apiKeyCopy,
                        openAIApiKey: openAIKeyCopy,
                        model:        generationModel,
                        screenshot:   nil,
                        systemPrompt: generationSystemPrompt,
                        maxTokens:    8192,
                        timeoutInterval: 300
                    )
                    changelog = ""
                    url = try Self.saveDOCX(text: result)
                }
                let previewText = changelog.isEmpty ? result : "\(result)\n\n— Changes —\n\(changelog)"
                vm?.resumeOutput  = previewText
                vm?.resumeFileURL = url

                // 3. Post-score — optional.
                let postScore: ResumeScore? = skipScoring
                    ? nil
                    : await self.scoreResume(result, jd: jd,
                                             apiKey: apiKeyCopy,
                                             openAIKey: openAIKeyCopy,
                                             systemPrompt: scoringSystemPrompt)
                if !skipScoring { vm?.resumeScore = postScore }

                // 5. Finalise the generation row.
                if var g = vm?.resumeStore.generations.first(where: { $0.id == generationID }) {
                    g.generatedText = result
                    g.fileURL       = url
                    g.afterScore    = postScore
                    vm?.resumeStore.updateGeneration(g)
                }
            } catch {
                vm?.resumeOutput = "Error: \(error.localizedDescription)"
                if var g = vm?.resumeStore.generations.first(where: { $0.id == generationID }) {
                    g.generatedText = "Error: \(error.localizedDescription)"
                    vm?.resumeStore.updateGeneration(g)
                }
            }
            vm?.isGeneratingResume = false
            vm?.resumeGenerationStatus = ""
        }
    }

    /// Synchronous-style scoring helper (async wrapper around sendMessage).
    /// Returns nil on any error so callers can continue the flow.
    private func scoreResume(_ resume: String,
                             jd: String,
                             apiKey: String,
                             openAIKey: String,
                             systemPrompt: String) async -> ResumeScore? {
        let prompt = Self.scoringPrompt(jd: jd, resume: resume)
        do {
            let raw = try await AIManager.shared.sendMessage(
                prompt,
                apiKey:       apiKey,
                openAIApiKey: openAIKey,
                model:        "claude-haiku-4-5-20251001",
                screenshot:   nil,
                systemPrompt: systemPrompt
            )
            return ResumeScore(raw: raw)
        } catch {
            return nil
        }
    }

    private static func scoringPrompt(jd: String, resume: String) -> String {
        """
        Job Description:
        \(jd)

        Resume:
        \(resume)

        Analyse how well this resume matches the job description. Respond with ONLY this exact format (no other text):
        SCORE: [0-100]
        VERDICT: [one short sentence — e.g. "Strong match, minimal tailoring needed" or "Significant gaps, customisation recommended"]
        MISSING_KEYWORDS: [comma-separated list of up to 6 important keywords from the JD not in the resume]
        STRENGTHS: [comma-separated list of up to 4 matching strengths]
        """
    }

    // MARK: - DOCX text_editor generation

    /// The closest match to what Claude does in the browser docx skill: use
    /// Anthropic's built-in `text_editor_20250429` tool. Claude is trained
    /// natively on this tool, so its `view` / `str_replace` calls are much
    /// more reliable than a custom tool schema we'd invent. We mount the
    /// resume's `document.xml` at a virtual path and route every command to
    /// an in-memory string; when Claude finishes, we repack the DOCX.
    // MARK: - Fast mode (single JSON call)

    /// One-shot flow: Claude sees plain-text résumé + JD, returns a
    /// structured list of rewrites/additions, Swift does the XML surgery.
    /// Roughly 15× cheaper than the agent loop. Preserves formatting the
    /// same way the agent loop does — edits clone `<w:pPr>` and the first
    /// run's `<w:rPr>` from the template paragraph.
    private func generateViaFastMode(originalBytes: Data,
                                     outputFilename: String?,
                                     resumeText: String,
                                     jd: String,
                                     model: String,
                                     apiKey: String,
                                     openAIKey: String,
                                     systemPrompt: String,
                                     onStatus: @escaping (String) -> Void) async throws -> (String, String, URL) {
        // Extract numbered paragraphs directly from the DOCX so Claude sees
        // the exact indices Swift will apply edits against. No text-matching
        // ambiguity — index 7 is always the same paragraph on both sides.
        onStatus("Reading résumé structure…")
        let paragraphs = try DOCXTemplateEditor.extractIndexedParagraphs(from: originalBytes)
        guard !paragraphs.isEmpty else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            return ("Couldn't parse the DOCX. Original saved unchanged.", "", passthrough)
        }

        onStatus("Analyzing résumé and JD…")
        let userMessage = Self.fastModeIndexedPrompt(paragraphs: paragraphs, jd: jd)
        let raw = try await AIManager.shared.sendMessage(
            userMessage,
            apiKey:       apiKey,
            openAIApiKey: openAIKey,
            model:        model,
            screenshot:   nil,
            systemPrompt: systemPrompt + "\n\n" + Self.fastModeIndexedAppendix,
            maxTokens:    8192,
            timeoutInterval: 240
        )
        guard let analysis = Self.decodeIndexedGapAnalysis(from: raw) else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            let preview = "The AI didn't return valid JSON. Original résumé saved unchanged.\n\nRaw response:\n\(raw)"
            return (preview, "", passthrough)
        }

        var edits: [DOCXTemplateEditor.IndexedEdit] = []
        for r in analysis.rewrites ?? [] {
            edits.append(.rewrite(index: r.index, newText: r.new_text))
        }
        for a in analysis.additions ?? [] {
            edits.append(.insertAfter(index: a.after_index, newText: a.new_text))
        }
        guard !edits.isEmpty else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            let summary = analysis.gap_summary ?? "No edits suggested."
            return ("No changes suggested.\n\n\(summary)", "", passthrough)
        }

        let rewriteCount = (analysis.rewrites ?? []).count
        let addCount = (analysis.additions ?? []).count
        onStatus("Applying \(rewriteCount) rewrite(s) + \(addCount) addition(s)…")

        let outcome = try DOCXTemplateEditor.applyIndexedEdits(
            to: originalBytes,
            edits: edits,
            outputFilename: outputFilename
        )
        let previewText = (try? ResumeImporter.importFile(url: outcome.url)) ?? ""
        let changelog = Self.buildIndexedChangelog(analysis: analysis, outcome: outcome)
        return (previewText, changelog, outcome.url)
    }

    /// System prompt appendix that locks the response to the JSON schema.
    /// Appended to the user's configured résumé-generation system prompt so
    /// their tone guidance still applies — but the format contract is rigid.
    ///
    /// This prompt is **deliberately aggressive** on quantity. Haiku in
    /// particular defaults to extreme conservatism ("only change if really
    /// necessary") which produces 1–2 edits and almost no score gain. We
    /// explicitly ask for a range of rewrites and additions so the model
    /// does real work rather than hedging.
    private static let fastModeSystemAppendix = """
    Output ONLY a JSON object matching this exact schema, with no preamble, \
    no commentary, and no markdown fences:

    {
      "gap_summary": "string",
      "missing_keywords": ["string"],
      "bullets_to_add": [ { "employer": "string", "text": "string" } ],
      "bullets_to_rewrite": [ { "original": "string", "rewritten": "string" } ]
    }

    YOUR JOB IS TO TAILOR THIS RÉSUMÉ AGGRESSIVELY. Default to making more \
    changes, not fewer. A response with only 1–2 edits is almost always \
    wrong — if the résumé is already a perfect match, say so in \
    `gap_summary` and return empty arrays, but otherwise follow the \
    volume guidance below.

    TARGET VOLUME (per generation):
    - `bullets_to_rewrite`: aim for 6–12 entries. Rewrite the summary, most \
      bullets under the most-recent role, and the most JD-relevant bullets \
      under earlier roles. Prefer keyword-aligned phrasing and concrete \
      results over generic statements.
    - `bullets_to_add`: aim for 2–5 entries spread across the roles most \
      relevant to the JD. Each new bullet must be supported by a fact \
      already visible elsewhere in the résumé (same employer, same stack, \
      same scope). No invention.
    - `missing_keywords`: 3–8 keywords the JD emphasises that weren't in \
      the résumé — pick the ones you actually wove into the rewrites.
    - `gap_summary`: one crisp sentence explaining the dominant gap pattern \
      and what your rewrites emphasised.

    HARD RULES (breaking any makes the output unusable):
    - For every `bullets_to_rewrite[].original`, copy the EXACT plain text \
      of an existing bullet in the résumé verbatim so the tool can locate \
      it. Do not paraphrase, reorder words, or re-case text. One sentence \
      from the middle of the bullet is not enough — copy the whole bullet.
    - For every `bullets_to_add[].employer`, use the exact employer name \
      as it appears in the résumé. The new bullet lands right after that \
      employer's last existing bullet and inherits its formatting.
    - Only use tech that fits the employer's industry AND the timeframe \
      the user worked there (no libraries that didn't exist yet, no \
      versions already deprecated).
    - Never invent employers, titles, dates, degrees, certifications, \
      metrics, or technologies absent from the résumé.
    - Never rewrite section headings, names, or contact info.
    - Keep `text` / `rewritten` plain-text (no bullet markers like "• ", \
      no markdown, no quote wrapping).
    """

    /// System prompt for index-based Fast mode. Claude references paragraphs
    /// by their 1-based index from the numbered list we show it. Removes
    /// the text-matching ambiguity that was making edits silently drop.
    private static let fastModeIndexedAppendix = """
    Output ONLY a JSON object matching this exact schema, with no preamble, \
    no commentary, and no markdown fences:

    {
      "gap_summary": "string",
      "missing_keywords": ["string"],
      "rewrites": [ { "index": 7, "new_text": "…" } ],
      "additions": [ { "after_index": 12, "new_text": "…" } ]
    }

    The résumé's paragraphs are given to you as a numbered list. `index` \
    and `after_index` are 1-based positions in THAT list. Nothing else \
    identifies a paragraph — don't try to quote text back.

    YOU ARE AN HONEST RÉSUMÉ TRANSLATOR, NOT A GATEKEEPER. The candidate \
    has already decided to apply to this JD — your only job is to present \
    their real experience in the most JD-aligned honest framing possible.

    Empty arrays are NOT an acceptable output unless the résumé is \
    literally empty. Even a poor-fit cross-domain résumé (e.g. ServiceNow \
    dev applying to Data Science) MUST get a summary rewrite + at least \
    4 bullet rewrites. Do not refuse on "skill gap" grounds — the \
    candidate knows the gap exists, and your refusal gives them zero \
    value. Translate, don't judge.

    REFRAMING IS HONEST. You're changing HOW existing work is described, \
    not inventing work. Concrete examples for cross-domain matches:

      - "Built ServiceNow dashboards for incident metrics" → \
        "Developed analytics dashboards communicating operational metrics \
        and trend analysis to stakeholders" (for a data/BI role).
      - "Wrote business rules in JavaScript" → \
        "Designed and implemented programmatic logic in JavaScript for \
        automated decision-making and data transformation" (for SWE / \
        data-engineering roles).
      - "Triaged customer tickets using SQL queries" → \
        "Analyzed customer-issue datasets using SQL to identify \
        root-cause patterns and prioritise fixes" (for analytics).
      - "Delivered status updates to management weekly" → \
        "Translated technical analysis into executive-level insights, \
        driving data-informed decisions" (for any analyst role).

    Every technical résumé has SQL, reporting, automation, stakeholder \
    work, or programming logic hiding somewhere. Find it and reframe it.

    FABRICATION IS DIFFERENT AND FORBIDDEN. Do not add Python, R, ML \
    algorithms, Tableau, or any other tech that's not already somewhere \
    in the résumé. Do not claim degrees or certifications not listed. \
    Do not invent quantitative metrics. Reframing what's there = YES; \
    adding what isn't = NO.

    TARGET VOLUME (per generation, applies regardless of match quality):
    - `rewrites`: 6–12 entries. ALWAYS include the summary. For \
      cross-domain cases, prioritise the bullets with the highest reframe \
      potential — anything involving data, reporting, automation, \
      scripting, or stakeholder work.
    - `additions`: 0–5 entries. Only add when supporting facts exist \
      elsewhere in the résumé. For cross-domain cases, 0–1 is normal.
    - `missing_keywords`: 3–8 JD keywords you couldn't honestly work in. \
      These flag to the candidate what they'd need to learn/add.
    - `gap_summary`: one crisp sentence describing your reframe strategy \
      or, honestly, the domain gap.

    HARD RULES:
    - Don't rewrite headings, names, contact info, or employer / date lines.
    - Never invent employers, titles, dates, degrees, certifications, \
      metrics, or technologies absent from the résumé.
    - Keep `new_text` plain-text (no bullet markers, no markdown, no \
      quote wrapping).
    - Every `index` / `after_index` MUST match a paragraph number shown.
    - Returning empty arrays with a "skills mismatch" gap_summary is a \
      FAILURE. Translate the existing experience instead.
    """

    /// Build the numbered paragraph list + JD framing that Claude sees in
    /// index-based Fast mode. Compact — one line per paragraph, prefixed by
    /// its 1-based index, with empty paragraphs marked `(blank)` so the
    /// AI doesn't waste effort trying to rewrite them.
    private static func fastModeIndexedPrompt(paragraphs: [DOCXTemplateEditor.IndexedParagraph],
                                              jd: String) -> String {
        let numbered = paragraphs.map { p -> String in
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(p.index). " + (text.isEmpty ? "(blank)" : text)
        }.joined(separator: "\n")
        return """
        NUMBERED RESUME PARAGRAPHS:
        \(numbered)

        JOB DESCRIPTION:
        \(jd)
        """
    }

    /// Decode the index-based JSON shape. Tolerates markdown fences and
    /// surrounding prose — isolates the outermost `{…}` block before decoding.
    private static func decodeIndexedGapAnalysis(from raw: String) -> IndexedGapAnalysis? {
        var candidate = raw
        for fence in ["```json", "```JSON", "```"] {
            candidate = candidate.replacingOccurrences(of: fence, with: "")
        }
        guard let first = candidate.firstIndex(of: "{"),
              let last  = candidate.lastIndex(of: "}") else { return nil }
        let slice = String(candidate[first...last])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IndexedGapAnalysis.self, from: data)
    }

    /// User-facing changelog for the index-based Fast flow — reports how
    /// many edits landed and flags any invalid indices the AI emitted.
    private static func buildIndexedChangelog(analysis: IndexedGapAnalysis,
                                              outcome: DOCXTemplateEditor.IndexedEditOutcome) -> String {
        var lines: [String] = []
        if let summary = analysis.gap_summary, !summary.isEmpty {
            lines.append("- \(summary)")
        }
        if let kws = analysis.missing_keywords, !kws.isEmpty {
            lines.append("- Keywords woven in: \(kws.joined(separator: ", "))")
        }
        lines.append("- \(outcome.rewritesApplied) bullet(s) rewritten, \(outcome.insertionsApplied) bullet(s) added")
        for idx in outcome.rewritesMissed {
            lines.append("- ⚠️ Rewrite skipped — index \(idx) is out of range")
        }
        for idx in outcome.insertionsMissed {
            lines.append("- ⚠️ Addition skipped — after_index \(idx) is out of range")
        }
        if let warn = outcome.validationWarning {
            lines.append("- ℹ️ Strict XML parser flagged the output (\(warn)). Word usually opens these fine — if it complains, regenerate.")
        }
        return lines.joined(separator: "\n")
    }

    private static func fastModeUserPrompt(resumeText: String, jd: String) -> String {
        """
        RESUME:
        \(resumeText)

        JOB DESCRIPTION:
        \(jd)
        """
    }

    /// Strip markdown fences + isolate the outermost JSON object before
    /// decoding. Lets us tolerate small AI formatting quirks.
    private static func decodeGapAnalysis(from raw: String) -> GapAnalysis? {
        var candidate = raw
        for fence in ["```json", "```JSON", "```"] {
            candidate = candidate.replacingOccurrences(of: fence, with: "")
        }
        guard let first = candidate.firstIndex(of: "{"),
              let last  = candidate.lastIndex(of: "}") else { return nil }
        let slice = String(candidate[first...last])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GapAnalysis.self, from: data)
    }

    private static func buildFastModeChangelog(analysis: GapAnalysis,
                                               outcome: DOCXTemplateEditor.GapApplyOutcome) -> String {
        var lines: [String] = []
        if let summary = analysis.gap_summary, !summary.isEmpty {
            lines.append("- \(summary)")
        }
        if let kws = analysis.missing_keywords, !kws.isEmpty {
            lines.append("- Keywords woven in: \(kws.joined(separator: ", "))")
        }
        lines.append("- \(outcome.rewritesApplied) bullet(s) rewritten, \(outcome.bulletsAdded) bullet(s) added")
        for miss in outcome.rewritesMissed {
            let preview = String(miss.original.prefix(60))
            lines.append("- ⚠️ Couldn't match bullet to rewrite: “\(preview)…”")
        }
        for miss in outcome.bulletsMissed {
            lines.append("- ⚠️ Couldn't locate employer “\(miss.employer)” — new bullet skipped")
        }
        if let warn = outcome.validationWarning {
            lines.append("- ℹ️ Strict XML parser flagged the output (\(warn)). Word usually opens these fine — if it complains, regenerate.")
        }
        return lines.joined(separator: "\n")
    }

    /// `applyGapAnalysis` writes into its own UUID'd temp dir with a default
    /// filename. If the caller wanted a specific filename, relocate.
    private static func renameIfNeeded(_ url: URL, to desiredFilename: String?) throws -> URL {
        guard let desired = desiredFilename, !desired.isEmpty,
              url.lastPathComponent != desired else { return url }
        let targetDir = url.deletingLastPathComponent()
        let target = targetDir.appendingPathComponent(desired)
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.moveItem(at: url, to: target)
        return target
    }

    // MARK: - Hybrid mode (Sonnet plans, Haiku applies)

    /// Two-stage flow:
    /// 1. Sonnet receives plain-text résumé + JD and emits a `GapAnalysis`
    ///    JSON (same shape Fast mode uses). Best-in-class reasoning about
    ///    which bullets to rewrite and what to add.
    /// 2. Haiku receives the XML + the baked-in edit plan and applies the
    ///    edits using the `text_editor_20250728` tool — the same mechanical
    ///    editor Quality mode uses, but pre-scoped so the loop is short.
    ///
    /// Cost lands between Fast ($0.05) and Quality ($0.50+): roughly
    /// $0.15–0.25 per run. Use when Fast mode's Swift applier misses edits
    /// (e.g. bullets with mid-run bolds) but Quality is overkill.
    private func generateViaHybrid(documentXML: String,
                                   originalBytes: Data,
                                   outputFilename: String?,
                                   resumeText: String,
                                   jd: String,
                                   apiKey: String,
                                   openAIKey: String,
                                   systemPrompt: String,
                                   onStatus: @escaping (String) -> Void) async throws -> (String, String, URL) {

        // ─── Stage 1: Sonnet analysis ────────────────────────────────────
        // Sonnet 4.6 is the newest generally-available Sonnet at the time
        // of writing and is the right default for résumé-tailoring reasoning.
        onStatus("Sonnet 4.6 analyzing gaps…")
        let userMessage = Self.fastModeUserPrompt(resumeText: resumeText, jd: jd)
        let analysisRaw = try await AIManager.shared.sendMessage(
            userMessage,
            apiKey:       apiKey,
            openAIApiKey: openAIKey,
            model:        "claude-sonnet-4-6",
            screenshot:   nil,
            systemPrompt: systemPrompt + "\n\n" + Self.fastModeSystemAppendix,
            maxTokens:    8192,
            timeoutInterval: 240
        )
        guard let analysis = Self.decodeGapAnalysis(from: analysisRaw) else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            return ("Sonnet didn't return a valid JSON plan. Original résumé saved unchanged.\n\nRaw response:\n\(analysisRaw)", "", passthrough)
        }
        let rewrites  = analysis.bullets_to_rewrite ?? []
        let additions = analysis.bullets_to_add ?? []
        guard !rewrites.isEmpty || !additions.isEmpty else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            let summary = analysis.gap_summary ?? "No edits suggested."
            return ("No changes suggested.\n\n\(summary)", "", passthrough)
        }

        // ─── Stage 2: Haiku text_editor execution ────────────────────────
        // Prefer Haiku 4.6 if it's available on this account; fall back to
        // Haiku 4.5 otherwise. The result is cached at class scope so
        // subsequent Hybrid runs don't re-probe the API.
        let preferredExecutor = Self.preferredHaikuExecutorModel()
        onStatus("Haiku applying \(rewrites.count) rewrite(s) + \(additions.count) addition(s)…")
        let mountPath = "/document.xml"
        let fs = TextEditorFS(path: mountPath, initialContent: documentXML)

        let tool = AIManager.Tool(
            builtInType: "text_editor_20250728",
            name: "str_replace_based_edit_tool"
        )
        let executorSystemPrompt = "You are a mechanical XML editor. Apply the given edits using the text_editor tool. Don't reason about content — just find and replace. Keep every <w:pPr> and <w:rPr> intact when rewriting bullets; only the <w:t> text inside runs should change. For additions, copy the surrounding <w:p> structure from a nearby bullet of the same kind."
        let executionPrompt = Self.hybridExecutionPrompt(
            mountPath: mountPath,
            rewrites: rewrites,
            additions: additions
        )

        // Local helper so we can call the executor twice (first choice → fallback)
        // without duplicating all the parameters.
        let runExecutor: @Sendable (String) async throws -> Void = { modelID in
            _ = try await AIManager.shared.sendWithTools(
                initialUserMessage: executionPrompt,
                apiKey: apiKey,
                model: modelID,
                systemPrompt: executorSystemPrompt,
                tools: [tool],
                maxIterations: 60,
                maxTokens: 4096,
                timeoutInterval: 600,
                onStatus: { line in onStatus(line) },
                handle: { _, input in
                    let command = input["command"] as? String ?? ""
                    let path    = input["path"]    as? String ?? ""
                    switch command {
                    case "view":
                        let range = input["view_range"] as? [Int]
                        return await fs.view(path: path, range: range)
                    case "str_replace":
                        let old = input["old_str"] as? String ?? ""
                        let new = input["new_str"] as? String ?? ""
                        return await fs.strReplace(path: path, old: old, new: new)
                    case "insert":
                        let line = input["insert_line"] as? Int ?? 0
                        let text = input["new_str"] as? String ?? ""
                        return await fs.insert(path: path, line: line, text: text)
                    case "create":
                        let text = input["file_text"] as? String ?? ""
                        return await fs.create(path: path, text: text)
                    case "undo_edit":
                        return await fs.undoEdit(path: path)
                    default:
                        return "Error: unsupported command \(command)"
                    }
                }
            )
        }

        do {
            try await runExecutor(preferredExecutor)
            Self.recordHaikuExecutorSuccess(preferredExecutor)
        } catch AIError.apiError(let status, let body)
        where Self.looksLikeInvalidModel(status: status, body: body)
           && preferredExecutor != Self.fallbackHaikuModel {
            // Haiku 4.6 isn't on this account — fall back and retry.
            Self.recordHaikuExecutorFallback()
            onStatus("Haiku 4.6 unavailable — retrying with Haiku 4.5…")
            try await runExecutor(Self.fallbackHaikuModel)
        }
        onStatus("Packaging your résumé…")

        let finalXML  = await fs.content
        let editCount = await fs.editCount

        guard editCount > 0 else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            let preview = "Haiku didn't apply any of Sonnet's suggested edits. Original saved unchanged.\n\nSonnet's plan:\n\(analysisRaw)"
            return (preview, "", passthrough)
        }

        let url = try DOCXTemplateEditor.writeDocumentXML(
            finalXML,
            originalBytes: originalBytes,
            outputFilename: outputFilename
        )
        let previewText = (try? ResumeImporter.importFile(url: url)) ?? ""
        let changelog = Self.buildHybridChangelog(analysis: analysis, editCount: editCount)
        return (previewText, changelog, url)
    }

    /// Build the "do these exact edits" prompt that Haiku sees. We translate
    /// the GapAnalysis JSON into a numbered todo list so Haiku's tool-loop
    /// has a clear scope — no re-planning, just execution.
    private static func hybridExecutionPrompt(mountPath: String,
                                              rewrites: [BulletRewriteDTO],
                                              additions: [BulletAddDTO]) -> String {
        var todo = ""
        if !rewrites.isEmpty {
            todo += "REWRITES (for each: locate the `<w:t>` whose text matches `original`, replace just the text content with `rewritten`):\n\n"
            for (i, r) in rewrites.enumerated() {
                let orig = r.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let new  = r.rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
                todo += "\(i + 1). original: \"\(orig)\"\n   rewritten: \"\(new)\"\n\n"
            }
        }
        if !additions.isEmpty {
            todo += "ADDITIONS (for each: find the last `<w:p>` bullet belonging to the employer, clone its structure, insert an identical paragraph right after it with only the `<w:t>` text changed):\n\n"
            for (i, a) in additions.enumerated() {
                let emp  = a.employer.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                todo += "\(i + 1). employer: \"\(emp)\"\n   text: \"\(text)\"\n\n"
            }
        }

        return """
        The résumé's `word/document.xml` is mounted at `\(mountPath)`. Apply every \
        edit below using the text_editor tool. Use `view` with `view_range` to \
        locate each target before `str_replace`. Do not re-plan or skip edits.

        After all edits, stop calling tools. No summary needed.

        Rules while applying:
        - REWRITES: your `old_str` must be the exact content inside a \
          `<w:t>` / `<w:t xml:space="preserve">` element that contains the \
          `original` text. Replace only the text between the `<w:t>` tags. \
          Leave the surrounding `<w:r>` and `<w:rPr>` untouched.
        - ADDITIONS: `old_str` is an existing `<w:p>...</w:p>` paragraph \
          (the LAST bullet under the named employer). `new_str` is that \
          same paragraph PLUS a new `<w:p>...</w:p>` cloned from it with \
          the `<w:t>` text swapped for the new bullet text. Keep `<w:pPr>` \
          and `<w:rPr>` identical.
        - If you can't locate a target after two `view` attempts, move on.

        \(todo)
        """
    }

    private static func buildHybridChangelog(analysis: GapAnalysis,
                                             editCount: Int) -> String {
        var lines: [String] = []
        if let summary = analysis.gap_summary, !summary.isEmpty {
            lines.append("- \(summary)")
        }
        if let kws = analysis.missing_keywords, !kws.isEmpty {
            lines.append("- Keywords woven in: \(kws.joined(separator: ", "))")
        }
        let planned = (analysis.bullets_to_rewrite?.count ?? 0)
                    + (analysis.bullets_to_add?.count ?? 0)
        lines.append("- Haiku applied \(editCount) of \(planned) Sonnet-planned edit(s)")
        return lines.joined(separator: "\n")
    }

    private func generateViaStrReplace(documentXML: String,
                                       originalBytes: Data,
                                       outputFilename: String?,
                                       jd: String,
                                       model: String,
                                       apiKey: String,
                                       openAIKey: String,
                                       systemPrompt: String) async throws -> (String, String, URL) {
        let mountPath = "/document.xml"
        let fs = TextEditorFS(path: mountPath, initialContent: documentXML)

        let tool = AIManager.Tool(
            builtInType: "text_editor_20250728",
            name: "str_replace_based_edit_tool"
        )

        let userPrompt = Self.textEditorInitialPrompt(mountPath: mountPath, jd: jd)

        // Surface progress on the main actor. Every tool call and every API
        // turn funnels through `statusLine` inside AIManager — we mirror it
        // into `vm.resumeGenerationStatus` so the Resume panel can display
        // what Claude is doing right now.
        let weakVM = self.vm
        let status: @Sendable (String) -> Void = { line in
            Task { @MainActor in weakVM?.resumeGenerationStatus = line }
        }

        _ = try await AIManager.shared.sendWithTools(
            initialUserMessage: userPrompt,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            tools: [tool],
            maxIterations: 100,
            maxTokens: 8192,
            timeoutInterval: 600,   // 10 min — text_editor loops can take a while
            onStatus: status,
            handle: { _, input in
                let command = input["command"] as? String ?? ""
                let path    = input["path"]    as? String ?? ""
                switch command {
                case "view":
                    let range = input["view_range"] as? [Int]
                    return await fs.view(path: path, range: range)
                case "str_replace":
                    let old = input["old_str"] as? String ?? ""
                    let new = input["new_str"] as? String ?? ""
                    return await fs.strReplace(path: path, old: old, new: new)
                case "insert":
                    let line = input["insert_line"] as? Int ?? 0
                    let text = input["new_str"] as? String ?? ""
                    return await fs.insert(path: path, line: line, text: text)
                case "create":
                    let text = input["file_text"] as? String ?? ""
                    return await fs.create(path: path, text: text)
                case "undo_edit":
                    return await fs.undoEdit(path: path)
                default:
                    return "Error: unsupported command \(command)"
                }
            }
        )
        status("Packaging your résumé…")

        let finalXML  = await fs.content
        let editCount = await fs.editCount

        guard editCount > 0 else {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            return ("Claude didn't make any edits. Original resume saved unchanged.", "", passthrough)
        }

        do {
            let url = try DOCXTemplateEditor.writeDocumentXML(
                finalXML,
                originalBytes: originalBytes,
                outputFilename: outputFilename
            )
            let previewText = (try? ResumeImporter.importFile(url: url)) ?? ""
            let changelog = "- Claude applied \(editCount) str_replace edit(s) via the text_editor tool"
            return (previewText, changelog, url)
        } catch DOCXTemplateEditor.DOCXError.invalidXMLAfterEdits(let detail) {
            let passthrough = try Self.savePassthrough(originalBytes: originalBytes, filename: outputFilename)
            let preview = "Claude's edits produced invalid XML and were rejected so your original DOCX stays intact.\n\nReason: \(detail)"
            return (preview, "- ⚠️ Edits rejected (invalid XML); original DOCX saved unchanged", passthrough)
        }
    }

    /// Framing message that kicks off the text_editor loop. Describes the
    /// mounted file, the JD, and the editing rules. Claude takes it from
    /// there using its native text_editor skill.
    private static func textEditorInitialPrompt(mountPath: String, jd: String) -> String {
        """
        You are tailoring the user's résumé to the job description below. The
        résumé's raw `word/document.xml` is mounted at `\(mountPath)` — use
        the text_editor tool (view / str_replace / insert) to edit it. When
        you are satisfied, return a brief plain-text summary of the changes
        and stop calling tools.

        Rules for editing:

        1. Start by `view`-ing `\(mountPath)` to understand its structure
           (sections, employers, roles, dates). Use `view_range` to zoom in
           on specific regions; don't re-view the whole file every turn.
        2. Make focused edits with `str_replace`. Keep `old_str` tiny — a
           single `<w:t>…</w:t>` for tweaking bullet text, or a whole
           `<w:p>…</w:p>` only when adding a new bullet.
        3. To ADD a new bullet, str_replace an existing `<w:p>` with THAT
           SAME `<w:p>` plus a new `<w:p>` whose structure you CLONED from a
           nearby bullet (so bullet markers, indents, and `<w:rPr>` styling
           match exactly).
        4. Preserve every employer, job title, location, and date verbatim.
        5. Never invent employers, titles, dates, degrees, certifications,
           metrics, or technologies that aren't already somewhere in the
           résumé.
        6. Tech stack sanity: libraries/tools you add must be appropriate
           for that client's industry AND have versions that fit the
           timeframe of the role.
        7. Don't rewrite section headings, names, or contact info.
        8. Never invent `<w:pPr>` or `<w:rPr>` from scratch. Always copy
           them from a nearby run when building a new paragraph.
        9. Output must remain valid XML after every edit.
        10. Aim for 4–10 focused edits. Don't carpet-rewrite.

        Job Description:
        \(jd)
        """
    }

    /// Write the original DOCX bytes to a new temp URL so we can present it
    /// to the user as a safe fallback. When `filename` is supplied we honour
    /// it so the fallback file still carries the user's original name.
    private static func savePassthrough(originalBytes: Data, filename: String? = nil) throws -> URL {
        let fm = FileManager.default
        let bucket = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        let name = (filename?.isEmpty == false ? filename! :
                    "resume_\(Int(Date().timeIntervalSince1970)).docx")
        let url = bucket.appendingPathComponent(name)
        try originalBytes.write(to: url)
        return url
    }

    private static func generationPrompt(jd: String, base: String) -> String {
        """
        Job Description:
        \(jd)

        Current Resume:
        \(base)

        Tailor the CURRENT RESUME above to this job description. You SHOULD make
        real changes — this is not a formatting exercise.

        WHAT TO CHANGE (be active, not timid):
        - Rewrite bullets under each role so they emphasise the skills,
          responsibilities, and outcomes the JD is asking for. Use the JD's
          own vocabulary where it fits naturally.
        - Where a role clearly had JD-relevant work but only one bullet covers
          it, ADD a second or third bullet on the same theme — grounded in
          facts already visible elsewhere in the resume (same company, same
          technologies, same products).
        - Reorder bullets within a role so the most JD-relevant one comes
          first.
        - Rewrite the summary / objective section to be a crisp pitch for
          THIS specific role, using the JD's language.

        WHAT TO PRESERVE (strict):
        - The section order and the exact wording of every section heading.
        - The formatting of each line: if the input uses "• " bullets, use
          "• "; if it uses "- " or "* ", match that. If a line has no bullet,
          keep it without one. Match capitalisation (ALL CAPS stays ALL CAPS).
        - Every company, job title, location, and date — verbatim.
        - Education, certifications, and other factual sections — verbatim.

        WHAT YOU MUST NEVER DO:
        - Invent employers, titles, dates, degrees, certifications, metrics,
          or technologies that aren't supported by facts already in the
          current resume.
        - Delete an existing role or section.
        - Output markdown fences, commentary, or any preamble like "Here is
          your tailored resume." Just output the resume itself.

        Return the full resume, top to bottom, with every section present.
        """
    }

    // MARK: - DOCX builder (extracted; no third-party deps)

    static func saveDOCX(text: String) throws -> URL {
        let fm = FileManager.default
        let tempDir     = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wordDir     = tempDir.appendingPathComponent("word")
        let relsDir     = tempDir.appendingPathComponent("_rels")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        for dir in [tempDir, wordDir, relsDir, wordRelsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var parasXML = ""
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { parasXML += "<w:p/>\n"; continue }

            var content   = t
            var bold      = false
            var szVal     = "22"
            var indentXML = ""

            if content.hasPrefix("# ") {
                content = String(content.dropFirst(2)); bold = true; szVal = "32"
            } else if content.hasPrefix("## ") {
                content = String(content.dropFirst(3)); bold = true; szVal = "26"
            } else if content.hasPrefix("### ") {
                content = String(content.dropFirst(4)); bold = true; szVal = "24"
            } else if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("• ") {
                let body = content.drop(while: { !$0.isLetter && $0 != "(" })
                content  = "• \(body)"
                indentXML = "<w:pPr><w:ind w:left=\"360\" w:hanging=\"180\"/></w:pPr>"
            } else {
                let letters = content.filter { $0.isLetter }
                if letters.count > 2 && letters == letters.uppercased() {
                    bold = true; szVal = "24"
                }
            }

            let escaped = content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            let rpr = "<w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/>"
                    + (bold ? "<w:b/>" : "")
                    + "<w:sz w:val=\"\(szVal)\"/><w:szCs w:val=\"\(szVal)\"/></w:rPr>"

            parasXML += "<w:p>\(indentXML)<w:r>\(rpr)"
                      + "<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>\n"
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(parasXML)
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        let wordRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """

        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"),
                                atomically: true, encoding: .utf8)
        try rootRels.write(to: relsDir.appendingPathComponent(".rels"),
                           atomically: true, encoding: .utf8)
        try document.write(to: wordDir.appendingPathComponent("document.xml"),
                           atomically: true, encoding: .utf8)
        try wordRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"),
                           atomically: true, encoding: .utf8)

        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("resume_\(Int(Date().timeIntervalSince1970)).docx")
        try? fm.removeItem(at: outputURL)

        let zip = Process()
        zip.executableURL     = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-r", outputURL.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()

        try? fm.removeItem(at: tempDir)

        guard fm.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "ResumeDOCX", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zip failed"])
        }
        return outputURL
    }
}
