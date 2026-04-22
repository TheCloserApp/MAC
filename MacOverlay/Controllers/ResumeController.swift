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

/// Owns resume generation + ATS scoring + DOCX export. The VM still holds the
/// per-run state (resumeJD, resumeOutput, resumeScore, etc.) but all logic to
/// drive it lives here.
@MainActor
final class ResumeController {
    private weak var vm: OverlayViewModel?

    init(vm: OverlayViewModel) {
        self.vm = vm
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

        Task { [weak self, weak vm] in
            guard let self else { return }

            // 1. Pre-score (parallel with generation below would be ideal, but
            //    we do it serially to keep logic simple + display before-gen).
            let preScore = await self.scoreResume(base, jd: jd,
                                                  apiKey: apiKeyCopy,
                                                  openAIKey: openAIKeyCopy,
                                                  systemPrompt: scoringSystemPrompt)
            vm?.resumeScore = preScore
            if var g = vm?.resumeStore.generations.first(where: { $0.id == generationID }) {
                g.beforeScore = preScore
                vm?.resumeStore.updateGeneration(g)
            }

            // 2. Generate tailored output. Sonnet 4.6, 8192 tokens, 5 min timeout.
            //    Two paths:
            //    - STR_REPLACE MODE (preset imported from DOCX): send the full
            //      document.xml + JD to the AI; the AI returns a list of exact
            //      str_replace operations; Swift applies them verbatim to the
            //      XML and re-zips. Everything the AI doesn't touch stays
            //      byte-for-byte identical to the original document.
            //    - PLAIN MODE (otherwise): the AI returns the full resume text
            //      and we rebuild a fresh DOCX from scratch.
            do {
                let result: String
                let changelog: String
                let url: URL
                if let originalBytes = preset.originalDOCX,
                   let xml = try? DOCXTemplateEditor.extractDocumentXML(from: originalBytes),
                   !xml.isEmpty {
                    let (r, c, u) = try await self.generateViaStrReplace(
                        documentXML: xml,
                        originalBytes: originalBytes,
                        outputFilename: preset.originalFilename,
                        jd: jd,
                        apiKey: apiKeyCopy,
                        openAIKey: openAIKeyCopy,
                        systemPrompt: generationSystemPrompt
                    )
                    result = r
                    changelog = c
                    url = u
                } else {
                    let plainPrompt = Self.generationPrompt(jd: jd, base: base)
                    result = try await AIManager.shared.sendMessage(
                        plainPrompt,
                        apiKey:       apiKeyCopy,
                        openAIApiKey: openAIKeyCopy,
                        model:        "claude-sonnet-4-6",
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

                // 4. Post-score the generated output.
                let postScore = await self.scoreResume(result, jd: jd,
                                                       apiKey: apiKeyCopy,
                                                       openAIKey: openAIKeyCopy,
                                                       systemPrompt: scoringSystemPrompt)
                vm?.resumeScore = postScore

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
    private func generateViaStrReplace(documentXML: String,
                                       originalBytes: Data,
                                       outputFilename: String?,
                                       jd: String,
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
            model: "claude-sonnet-4-6",
            systemPrompt: systemPrompt,
            tools: [tool],
            maxIterations: 40,
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
