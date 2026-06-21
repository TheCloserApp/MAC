import Foundation

/// Claude-skill-style DOCX editor: give the AI the full `document.xml` and
/// let it return a list of exact str_replace operations. The AI writes the
/// XML; Swift only unzips, applies verbatim string replacements, and re-zips.
///
/// This mirrors how the docx skill operates in Claude's browser — AI sees
/// the raw XML, uses str_replace to splice in changes, and tooling repacks
/// the archive. Formatting is preserved because the AI copies the surrounding
/// `<w:pPr>` / `<w:rPr>` structure when it needs to add or modify runs, and
/// anything it doesn't touch stays byte-for-byte identical to the original.
enum DOCXTemplateEditor {

    /// One exact-match string replacement. `old` is located in the document's
    /// `document.xml` and replaced with `new`. Applied once per replacement
    /// (first occurrence) — same semantics as Claude's str_replace tool.
    struct Replacement {
        let old: String
        let new: String
    }

    enum DOCXError: LocalizedError {
        case unreadable
        case zipFailed
        case missingDocumentXML
        case invalidXMLAfterEdits(detail: String)

        var errorDescription: String? {
            switch self {
            case .unreadable:         return "Could not read DOCX file"
            case .zipFailed:          return "Failed to repackage DOCX"
            case .missingDocumentXML: return "DOCX is missing word/document.xml"
            case .invalidXMLAfterEdits(let d):
                return "AI edits produced invalid XML: \(d)"
            }
        }
    }

    // MARK: - Public API

    /// Return the full `word/document.xml` as a string so callers can hand it
    /// to the AI.
    static func extractDocumentXML(from data: Data) throws -> String {
        let tempDir = try unzip(data)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard let xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }
        return xml
    }

    /// Apply `replacements` to the DOCX's `document.xml`, in order. Each
    /// replacement is applied to the FIRST occurrence of its `old` string.
    /// Replacements whose `old` can't be found are returned as `missed` so
    /// callers can log diagnostics — they are skipped, never error out.
    @discardableResult
    static func apply(replacements: [Replacement],
                      to data: Data) throws -> (url: URL, applied: Int, missed: [Replacement]) {
        let tempDir = try unzip(data)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard var xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }

        var applied = 0
        var missed: [Replacement] = []
        for r in replacements {
            if r.old.isEmpty { missed.append(r); continue }
            if let range = xml.range(of: r.old) {
                xml.replaceSubrange(range, with: r.new)
                applied += 1
            } else {
                missed.append(r)
            }
        }

        // Validate XML well-formedness. If the AI's edits broke the structure,
        // abort and let the caller fall back to the unedited original — we
        // never want to hand the user a corrupt DOCX.
        if let data = xml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            if !parser.parse() {
                let err = parser.parserError?.localizedDescription
                       ?? delegate.firstError
                       ?? "malformed XML"
                throw DOCXError.invalidXMLAfterEdits(detail: err)
            }
        }

        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        // Re-zip back into a .docx.
        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("resume_\(Int(Date().timeIntervalSince1970)).docx")
        try? fm.removeItem(at: outputURL)

        try Self.repackDOCX(from: tempDir, to: outputURL)
        return (outputURL, applied, missed)
    }

    // MARK: - Gap-analysis application (JSON schema flow)

    /// A bullet rewrite: the plain text of an existing paragraph and what
    /// it should become. Matching is by normalised plain text, not XML.
    struct BulletRewrite {
        let original: String
        let rewritten: String
    }

    /// A new bullet to inject. `employer` is the landmark used to locate
    /// which role the bullet belongs under — we insert it right after the
    /// last existing bullet of that employer's section.
    struct BulletAdd {
        let employer: String
        let text: String
    }

    /// Statistics returned from `applyGapAnalysis` so the UI can show the
    /// user what landed and what didn't.
    struct GapApplyOutcome {
        let url: URL
        let rewritesApplied: Int
        let rewritesMissed: [BulletRewrite]
        let bulletsAdded: Int
        let bulletsMissed: [BulletAdd]
        /// Non-fatal validation warning. Strict XMLParser is pickier than
        /// Word itself; when it objects but we still emit the file, the
        /// reason goes here so the user can tell the changelog why things
        /// look off if Word complains.
        var validationWarning: String?
    }

    /// Apply a gap-analysis to the DOCX: rewrite bullets whose plain text
    /// matches, and inject new bullets under the right employer. Formatting
    /// is preserved by keeping each paragraph's `<w:pPr>` and cloning the
    /// first `<w:r>`'s `<w:rPr>` for the new text.
    static func applyGapAnalysis(to originalBytes: Data,
                                 rewrites: [BulletRewrite],
                                 additions: [BulletAdd]) throws -> GapApplyOutcome {
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard var xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }

        // Work at the body level — paragraphs live inside <w:body>.
        guard let bodyStart = xml.range(of: "<w:body>"),
              let bodyEnd   = xml.range(of: "</w:body>") else {
            throw DOCXError.missingDocumentXML
        }
        let body = String(xml[bodyStart.upperBound..<bodyEnd.lowerBound])
        var (paragraphs, gaps) = splitBodySegments(body)

        var rewritesApplied = 0
        var rewritesMissed: [BulletRewrite] = []
        for r in rewrites {
            let needle = normaliseForMatch(r.original)
            guard !needle.isEmpty,
                  let idx = paragraphs.firstIndex(where: { normaliseForMatch(concatRunText(in: $0)) == needle })
                ?? paragraphs.firstIndex(where: { normaliseForMatch(concatRunText(in: $0)).contains(needle) })
            else {
                rewritesMissed.append(r)
                continue
            }
            // For paragraphs with tabs/breaks, use SURGICAL replacement so
            // we don't destroy alignment. For everything else, collapse
            // runs as before (clean text, loses bold sub-phrases).
            if hasInlineLayoutElements(paragraphs[idx]) {
                let edited = surgicallyReplaceLargestText(paragraphs[idx], with: r.rewritten)
                if edited == paragraphs[idx] {
                    rewritesMissed.append(r)
                    continue
                }
                paragraphs[idx] = edited
                rewritesApplied += 1
                continue
            }
            paragraphs[idx] = rewriteParagraphText(paragraphs[idx], to: r.rewritten)
            rewritesApplied += 1
        }

        // Apply additions SECOND (after rewrites) because indexing stays
        // stable during rewrites but shifts during inserts.
        var bulletsAdded = 0
        var bulletsMissed: [BulletAdd] = []
        for add in additions {
            guard let anchorIdx = findLastBullet(forEmployer: add.employer, in: paragraphs) else {
                bulletsMissed.append(add)
                continue
            }
            let template = paragraphs[anchorIdx]
            // Clone-for-insert strips unique-ID attributes so we don't end
            // up with two paragraphs sharing the same `w14:paraId` — which
            // makes Google Docs reject the upload.
            let injected = cloneParagraphForInsert(template, to: add.text)
            paragraphs.insert(injected, at: anchorIdx + 1)
            bulletsAdded += 1
        }

        // Rebuild body: re-interleave gaps and (possibly longer) paragraph
        // array. gaps.count originally == paragraphs.count + 1; inserts grew
        // paragraphs so we need empty gaps for the new slots.
        while gaps.count < paragraphs.count + 1 { gaps.insert("", at: gaps.count - 1) }
        var rebuiltBody = ""
        for i in 0..<paragraphs.count {
            rebuiltBody += gaps[i]
            rebuiltBody += paragraphs[i]
        }
        rebuiltBody += gaps.last ?? ""
        xml = String(xml[..<bodyStart.upperBound]) + rebuiltBody + String(xml[bodyEnd.lowerBound...])

        // Sanitise entities: HTML-named refs → numeric, stray `&` → `&amp;`.
        // Claude-generated text occasionally contains `&nbsp;`, `&mdash;`, or
        // a bare `&` that the strict validator below would reject even
        // though Word itself handles them fine.
        xml = Self.sanitizeXMLEntities(xml)

        // Run the well-formedness check but DON'T throw on failure — Word
        // is considerably more tolerant than Foundation's XMLParser. If the
        // parser objects, we still emit the file and surface the reason as
        // a warning in the outcome. Worst case the user regenerates; never
        // worse than blocking the whole operation.
        var validationWarning: String? = nil
        if let data = xml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            if !parser.parse() {
                validationWarning = parser.parserError?.localizedDescription
                                 ?? delegate.firstError ?? "strict parser objected"
            }
        }
        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("resume_\(Int(Date().timeIntervalSince1970)).docx")
        try? fm.removeItem(at: outputURL)
        try Self.repackDOCX(from: tempDir, to: outputURL)
        return GapApplyOutcome(
            url: outputURL,
            rewritesApplied: rewritesApplied,
            rewritesMissed: rewritesMissed,
            bulletsAdded: bulletsAdded,
            bulletsMissed: bulletsMissed,
            validationWarning: validationWarning
        )
    }

    // MARK: - Index-based Fast-mode primitives

    /// A single paragraph with a stable 1-based index, its plain text, and
    /// its original `<w:p>…</w:p>` XML. Used by the index-driven Fast mode
    /// flow so the AI can reference paragraphs by number instead of re-
    /// quoting text (which fails silently when whitespace or punctuation
    /// doesn't match character-for-character).
    ///
    /// `markedText` is the same plain text but with `[B]`/`[I]`/`[U]`
    /// markers wrapping bold / italic / underline runs. The model edits
    /// this string; `rewriteParagraphMarked` parses the markers back into
    /// runs so inline emphasis survives a full-paragraph rewrite.
    struct IndexedParagraph {
        let index: Int
        let text: String
        let markedText: String
        let xml: String
    }

    /// One AI-specified edit referenced by paragraph index rather than by
    /// text matching.
    ///
    /// - `.substringReplace`: precise in-run swap — Swift finds `old`
    ///   inside an existing `<w:t>` and replaces only those characters.
    ///   Run structure (bold sub-phrases, hyperlinks, font colour) stays
    ///   byte-for-byte intact. The surgical path; pref this whenever
    ///   only a few words need to change.
    /// - `.rewrite`: replace the paragraph's text. `newText` may carry
    ///   `[B]…[/B]` / `[I]…[/I]` / `[U]…[/U]` markers; we split it into
    ///   runs so inline emphasis is preserved even on full rewrites.
    /// - `.insertAfter`: clone the target paragraph's XML (bullet marker,
    ///   indent, fonts) and inject a new one after it carrying `newText`.
    enum IndexedEdit {
        case substringReplace(index: Int, replacements: [(old: String, new: String)])
        case rewrite(index: Int, newText: String)
        case insertAfter(index: Int, newText: String)
        /// Clone the table row that contains paragraph `referenceParagraphIndex`
        /// and inject a new row immediately after it. `cells` fills the new
        /// row's cells left-to-right; entries past the cell count are ignored
        /// and empty strings leave the cloned source cell untouched (handy
        /// when one column always carries the same label). The cloned row
        /// keeps all per-cell formatting — bold left columns, fills, borders,
        /// fonts — because we duplicate the row's XML wholesale and only
        /// swap each cell paragraph's text via `cloneParagraphForInsert`.
        case insertRowAfter(referenceParagraphIndex: Int, cells: [String])
    }

    /// Statistics returned from `applyIndexedEdits`.
    struct IndexedEditOutcome {
        let url: URL
        let rewritesApplied: Int
        let rewritesMissed: [Int]      // invalid indices
        let insertionsApplied: Int
        let insertionsMissed: [Int]
        /// Edits we deliberately refused because the target paragraph uses
        /// inline tabs / breaks for layout (right-aligned dates, tab-spaced
        /// skills lists, table-cell alignment). Collapsing those runs would
        /// destroy the visual layout.
        var layoutPreserved: [Int] = []
        /// Per-paragraph counts of surgical substring edits that succeeded
        /// and that we couldn't find a matching `<w:t>` for (the model
        /// misquoted `old`, e.g. paraphrased instead of copying).
        var surgicalApplied: Int = 0
        var surgicalMissed: Int = 0
        /// Table-row insertions. `rowsInserted` is the count that landed;
        /// `rowsMissed` carries the reference-paragraph indices whose
        /// enclosing row we couldn't locate (paragraph wasn't inside a
        /// `<w:tr>`, or the row XML was malformed).
        var rowsInserted: Int = 0
        var rowsMissed: [Int] = []
        /// Edits refused because the target paragraph is a section heading
        /// (Heading style or short all-caps line). The model is told not
        /// to touch these; the code makes it impossible.
        var headingsProtected: [Int] = []
        var validationWarning: String?
    }

    /// Inline character-level formatting we capture in `markedText` and
    /// rebuild from `[B]/[I]/[U]` markers. Scoped to bold / italic /
    /// underline only — colour, font, hyperlinks etc. ride along inside
    /// the cloned `<w:rPr>` baseline.
    struct RunFormat: OptionSet, Hashable {
        let rawValue: Int
        static let bold      = RunFormat(rawValue: 1 << 0)
        static let italic    = RunFormat(rawValue: 1 << 1)
        static let underline = RunFormat(rawValue: 1 << 2)
    }

    /// True when the paragraph reads like a section heading — explicit
    /// Word Heading style, or a short all-caps line ("EXPERIENCE",
    /// "TECHNICAL SKILLS", a name banner). The model is told never to
    /// touch headings, but prompts get ignored; this enforces it in code
    /// so a misbehaving response can't restructure the document.
    fileprivate static func looksLikeSectionHeading(_ paraXML: String) -> Bool {
        if paraXML.range(of: #"<w:pStyle w:val="Heading[^"]*""#,
                         options: .regularExpression) != nil { return true }
        let text = concatRunText(in: paraXML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 48 else { return false }
        let letterCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 3 else { return false }
        // All letters uppercase and none lowercase → header-shaped.
        return text.rangeOfCharacter(from: .lowercaseLetters) == nil
    }

    /// True if the paragraph contains inline layout elements that we'd
    /// destroy by collapsing its runs to a single text run.
    fileprivate static func hasInlineLayoutElements(_ paraXML: String) -> Bool {
        let markers = [
            "<w:tab/>", "<w:tab>", "<w:tab ",   // tab character (most common)
            "<w:br/>",  "<w:br>",  "<w:br ",    // soft line break
            "<w:cr/>",                           // carriage return
            "<w:ptab/>", "<w:ptab ",            // position tab
        ]
        for m in markers where paraXML.contains(m) { return true }
        return false
    }

    /// Heuristic: does this short text fragment look like a date or date
    /// range? Used to AVOID replacing date segments during surgical edits —
    /// a tab-aligned date in a role header should never be touched.
    fileprivate static func looksLikeDateSpan(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 50, !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("present") || lower.contains("current") ||
           lower.contains("ongoing") || lower.contains("till date") ||
           lower.contains("to date") {
            return true
        }
        // Month abbrev / name + year (e.g. "Dec 2023", "September 2021").
        if trimmed.range(of: #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{4}\b"#,
                         options: .regularExpression) != nil { return true }
        // Year-range: "2019 – 2021", "2019-2022".
        if trimmed.range(of: #"\b\d{4}\s*[–—\-]\s*\d{4}\b"#,
                         options: .regularExpression) != nil { return true }
        // MM/YYYY: "01/2020".
        if trimmed.range(of: #"\b\d{1,2}/\d{4}\b"#,
                         options: .regularExpression) != nil { return true }
        return false
    }

    /// Surgical text replacement: find every `<w:t>…</w:t>` element, drop
    /// any that look like dates, and swap the inner text of whichever
    /// non-date element holds the most characters. Everything else in the
    /// paragraph (other runs, tabs, breaks, bold sub-phrases, hyperlinks,
    /// run properties, paragraph properties) is left byte-for-byte intact.
    /// Used for paragraphs whose layout depends on inline tabs/breaks —
    /// collapsing those to a single run would shift dates onto a new line
    /// or scrunch tab-aligned skills lists.
    fileprivate static func surgicallyReplaceLargestText(_ paraXML: String,
                                                         with newText: String) -> String {
        let safeText = stripInvalidXMLChars(newText)
        let escaped  = escapeXML(safeText)
        guard let re = try? NSRegularExpression(pattern: #"<w:t\b[^>]*?>([\s\S]*?)</w:t>"#)
        else { return paraXML }
        let nsXml = paraXML as NSString
        let matches = re.matches(in: paraXML,
                                 range: NSRange(location: 0, length: nsXml.length))
        guard !matches.isEmpty else { return paraXML }

        var bestInnerRange: NSRange?
        var bestSize = 0
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let innerRange = match.range(at: 1)
            guard innerRange.location != NSNotFound else { continue }
            let raw = nsXml.substring(with: innerRange)
            let plain = unescapeXML(raw)
            if looksLikeDateSpan(plain) { continue }     // never touch date segments
            if raw.count > bestSize {
                bestSize = raw.count
                bestInnerRange = innerRange
            }
        }
        guard let target = bestInnerRange else { return paraXML }
        return nsXml.replacingCharacters(in: target, with: escaped) as String
    }

    /// Extract every paragraph as an `IndexedParagraph`. Empty paragraphs
    /// are kept (they may be meaningful spacers) so the numbering stays
    /// aligned between what the AI sees and what Swift applies against.
    static func extractIndexedParagraphs(from originalBytes: Data) throws -> [IndexedParagraph] {
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard let xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }
        guard let bs = xml.range(of: #"<w:body[^>]*>"#, options: .regularExpression),
              let be = xml.range(of: "</w:body>") else { return [] }
        let body = String(xml[bs.upperBound..<be.lowerBound])
        let (paraXMLs, _) = splitBodySegments(body)
        return paraXMLs.enumerated().map { (i, pXML) in
            IndexedParagraph(index: i + 1,
                             text: concatRunText(in: pXML),
                             markedText: markedRunText(in: pXML),
                             xml: pXML)
        }
    }

    /// Apply `edits` (indexed) and emit a new DOCX at `outputFilename`.
    /// - Invalid indices are collected in the outcome rather than thrown.
    /// - Rewrites preserve `<w:pPr>` + first-run `<w:rPr>`; only text changes.
    /// - Insertions clone the target paragraph's XML as the style template.
    static func applyIndexedEdits(to originalBytes: Data,
                                  edits: [IndexedEdit],
                                  outputFilename: String? = nil) throws -> IndexedEditOutcome {
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard var xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }
        guard let bodyStart = xml.range(of: #"<w:body[^>]*>"#, options: .regularExpression),
              let bodyEnd   = xml.range(of: "</w:body>") else {
            throw DOCXError.missingDocumentXML
        }
        let body = String(xml[bodyStart.upperBound..<bodyEnd.lowerBound])
        var (paragraphs, gaps) = splitBodySegments(body)

        // Bucket edits by action + target index for clean application.
        var surgicalByIdx: [Int: [(old: String, new: String)]] = [:]
        var rewritesByIdx: [Int: String] = [:]
        var insertionsByIdx: [Int: [String]] = [:]
        var rowInsertionsByRef: [Int: [[String]]] = [:]
        for edit in edits {
            switch edit {
            case .substringReplace(let idx, let reps):
                surgicalByIdx[idx, default: []].append(contentsOf: reps)
            case .rewrite(let idx, let newText):
                rewritesByIdx[idx] = newText
            case .insertAfter(let idx, let newText):
                insertionsByIdx[idx, default: []].append(newText)
            case .insertRowAfter(let refIdx, let cells):
                rowInsertionsByRef[refIdx, default: []].append(cells)
            }
        }

        // Resolve row insertions against the ORIGINAL paragraph/gap state
        // before any paragraph edits run — locating the enclosing `<w:tr>`
        // needs the gap structure intact, and we capture the row's XML
        // here so subsequent edits to cell paragraphs don't change what
        // gets cloned. Document-row indexing is stable across paragraph
        // edits (paragraph mutations never add or remove `<w:tr>` tags),
        // so we record each insertion's source `rowIndex0` and apply
        // them post-rebuild in descending order.
        struct PendingRowInsertion {
            let refIdx: Int
            let rowIndex0: Int
            let sourceRowXML: String
            let cells: [String]
        }
        var pendingRowInsertions: [PendingRowInsertion] = []
        var rowsMissed: [Int] = []
        var rowsInserted = 0
        for (refIdx, cellArrays) in rowInsertionsByRef {
            let refIdx0 = refIdx - 1
            guard refIdx0 >= 0, refIdx0 < paragraphs.count,
                  let span = locateEnclosingRow(refIndex0: refIdx0,
                                                paragraphs: paragraphs,
                                                gaps: gaps),
                  let rowXML = extractRowXML(firstIdx0: span.firstIdx0,
                                             lastIdx0: span.lastIdx0,
                                             paragraphs: paragraphs,
                                             gaps: gaps)
            else {
                rowsMissed.append(contentsOf: Array(repeating: refIdx, count: cellArrays.count))
                continue
            }
            // 0-based document row index for our source row. `<w:tr>`
            // openings only live in gaps; sum opens in gaps[0...firstIdx0]
            // and subtract 1 — the count includes our row's own opening.
            var rowIndex0 = -1
            for k in 0...span.firstIdx0 { rowIndex0 += countTrOpens(in: gaps[k]) }
            for cells in cellArrays {
                pendingRowInsertions.append(PendingRowInsertion(
                    refIdx: refIdx, rowIndex0: rowIndex0,
                    sourceRowXML: rowXML, cells: cells
                ))
            }
        }

        var rewritesApplied = 0
        var rewritesMissed: [Int] = []
        var insertionsApplied = 0
        var insertionsMissed: [Int] = []
        var layoutPreserved: [Int] = []
        var headingsProtected: [Int] = []
        var surgicalApplied = 0
        var surgicalMissed = 0

        // 1. Surgical substring replacements first. These preserve run
        //    structure (bold sub-phrases, hyperlinks, fonts) byte-for-byte
        //    because they only swap characters inside an existing `<w:t>`.
        //    Track which paragraphs landed at least one surgical edit so
        //    the rewrite pass below can skip them — if the model emitted
        //    both, surgical wins because it's the more conservative path.
        var paragraphsHandledBySurgical: Set<Int> = []
        for (idx, reps) in surgicalByIdx {
            let arrayIdx = idx - 1
            guard arrayIdx >= 0, arrayIdx < paragraphs.count else {
                surgicalMissed += reps.count
                continue
            }
            if looksLikeSectionHeading(paragraphs[arrayIdx]) {
                headingsProtected.append(idx)
                continue
            }
            let result = applySubstringReplacements(in: paragraphs[arrayIdx],
                                                    replacements: reps)
            paragraphs[arrayIdx] = result.xml
            surgicalApplied += result.applied
            surgicalMissed += result.missed
            if result.applied > 0 { paragraphsHandledBySurgical.insert(idx) }
        }

        // 2. Full-paragraph rewrites. Three branches:
        //    - Inline-layout paragraphs (tabs / breaks / position tabs):
        //      surgical-replace the largest non-date `<w:t>` so we don't
        //      collapse the layout.
        //    - Marker-bearing rewrites: split `[B]/[I]/[U]` spans into
        //      multiple runs so bold / italic / underline survive the
        //      rewrite. Preserves the original first-run rPr for font,
        //      colour, etc.
        //    - Plain rewrites: legacy single-run collapse.
        //    Paragraphs already handled by surgical edits above are
        //    skipped so we don't undo precise work with a coarse rewrite.
        for (idx, newText) in rewritesByIdx {
            if paragraphsHandledBySurgical.contains(idx) { continue }
            let arrayIdx = idx - 1
            guard arrayIdx >= 0, arrayIdx < paragraphs.count else {
                rewritesMissed.append(idx)
                continue
            }
            if looksLikeSectionHeading(paragraphs[arrayIdx]) {
                headingsProtected.append(idx)
                continue
            }
            if hasInlineLayoutElements(paragraphs[arrayIdx]) {
                let plain = stripFormatMarkers(newText)
                let edited = surgicallyReplaceLargestText(paragraphs[arrayIdx], with: plain)
                if edited == paragraphs[arrayIdx] {
                    layoutPreserved.append(idx)
                    continue
                }
                paragraphs[arrayIdx] = edited
                rewritesApplied += 1
                continue
            }
            // Models (Haiku especially) often return markerless rewrites
            // for paragraphs that carry inline emphasis. Before collapsing
            // to a single run, re-derive markers from the original spans —
            // any bold/italic/underline phrase that survives the rewrite
            // keeps its formatting.
            let effective = textContainsFormatMarkers(newText)
                ? newText
                : reapplyOriginalEmphasis(from: paragraphs[arrayIdx], to: newText)
            if textContainsFormatMarkers(effective) {
                paragraphs[arrayIdx] = rewriteParagraphMarked(paragraphs[arrayIdx],
                                                              marked: effective)
            } else {
                paragraphs[arrayIdx] = rewriteParagraphText(paragraphs[arrayIdx],
                                                             to: newText)
            }
            rewritesApplied += 1
        }

        // Apply insertions AFTER rewrites. Walk in reverse so array indices
        // don't shift out from under us.
        for idx in insertionsByIdx.keys.sorted(by: >) {
            let arrayIdx = idx - 1
            guard arrayIdx >= 0, arrayIdx < paragraphs.count else {
                insertionsMissed.append(idx)
                continue
            }
            // Cloning a tab/break-bearing paragraph as a template would
            // emit a new paragraph that loses those layout elements, so
            // refuse to clone such paragraphs.
            if hasInlineLayoutElements(paragraphs[arrayIdx]) {
                layoutPreserved.append(idx)
                continue
            }
            // Cloning a heading as the style template would inject a new
            // heading-styled paragraph mid-document — never what's wanted.
            if looksLikeSectionHeading(paragraphs[arrayIdx]) {
                headingsProtected.append(idx)
                continue
            }
            let template = paragraphs[arrayIdx]
            // Use the clone-for-insert variant so the new paragraphs don't
            // carry duplicate `w14:paraId` / `w:rsidR` with the template —
            // Google Docs rejects files with duplicate paragraph IDs.
            let newParas = insertionsByIdx[idx]!.map { cloneParagraphForInsert(template, to: $0) }
            paragraphs.insert(contentsOf: newParas, at: arrayIdx + 1)
            insertionsApplied += newParas.count
        }

        // Rebuild the body — pad gaps for newly inserted paragraphs with "".
        while gaps.count < paragraphs.count + 1 { gaps.insert("", at: gaps.count - 1) }
        var rebuilt = ""
        for i in 0..<paragraphs.count {
            rebuilt += gaps[i]
            rebuilt += paragraphs[i]
        }
        rebuilt += gaps.last ?? ""
        xml = String(xml[..<bodyStart.upperBound]) + rebuilt + String(xml[bodyEnd.lowerBound...])

        // Inject table-row insertions onto the rebuilt body. We work in
        // DESCENDING `rowIndex0` so each insertion's anchor (the N-th
        // `<w:tr>` in document order) stays valid — adding a row at
        // index K shifts every row with index > K by one, but doesn't
        // affect rows with smaller indices.
        for insertion in pendingRowInsertions.sorted(by: { $0.rowIndex0 > $1.rowIndex0 }) {
            let newRow = cloneRowWithCells(insertion.sourceRowXML, cells: insertion.cells)
            if let modified = injectRowAfter(rowIndex0: insertion.rowIndex0,
                                             newRow: newRow,
                                             in: xml) {
                xml = modified
                rowsInserted += 1
            } else {
                rowsMissed.append(insertion.refIdx)
            }
        }

        // Sanitise + (non-fatal) validate + write + re-zip.
        xml = Self.sanitizeXMLEntities(xml)
        var validationWarning: String? = nil
        if let data = xml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            if !parser.parse() {
                validationWarning = parser.parserError?.localizedDescription
                                 ?? delegate.firstError ?? "strict parser objected"
            }
        }
        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        let outputURL = try uniqueOutputURL(filename: outputFilename)
        try Self.repackDOCX(from: tempDir, to: outputURL)
        return IndexedEditOutcome(
            url: outputURL,
            rewritesApplied: rewritesApplied,
            rewritesMissed: rewritesMissed,
            insertionsApplied: insertionsApplied,
            insertionsMissed: insertionsMissed,
            layoutPreserved: layoutPreserved,
            surgicalApplied: surgicalApplied,
            surgicalMissed: surgicalMissed,
            rowsInserted: rowsInserted,
            rowsMissed: rowsMissed,
            headingsProtected: headingsProtected,
            validationWarning: validationWarning
        )
    }

    /// Plain text of every `<w:t>` element in every paragraph, joined by
    /// newlines. Useful to send to the AI as the "resume text" input.
    static func plainText(from originalBytes: Data) throws -> String {
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let docURL = tempDir.appendingPathComponent("word/document.xml")
        guard let xml = try? String(contentsOf: docURL, encoding: .utf8) else {
            throw DOCXError.missingDocumentXML
        }
        // Match `<w:body>` OR `<w:body …>` (with attributes) — some Word
        // writers emit `<w:body w:rsidR="…">` and the literal match would miss.
        guard let bs = xml.range(of: #"<w:body[^>]*>"#, options: .regularExpression),
              let be = xml.range(of: "</w:body>") else { return "" }
        let body = String(xml[bs.upperBound..<be.lowerBound])
        let (paras, _) = splitBodySegments(body)
        return paras.map { concatRunText(in: $0) }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .joined(separator: "\n")
    }

    // MARK: - Paragraph helpers

    /// Rebuild a `<w:p>`: keep its `<w:pPr>` verbatim, clone the first run's
    /// `<w:rPr>` as the style for the new text, replace all runs with a
    /// single run containing `newText`.
    private static func rewriteParagraphText(_ paraXML: String, to newText: String) -> String {
        // Strip XML-invalid control characters. XML 1.0 allows only 0x09
        // (tab), 0x0A (LF), 0x0D (CR) in the 0x00–0x1F range; anything
        // else is illegal and makes Word / Google Docs refuse to open
        // the file even when the broader schema is correct.
        let safeText = Self.stripInvalidXMLChars(newText)

        // Empty paragraph → nothing to replace against. Fall back to
        // injecting a single plain run with the new text.
        if paraXML.contains("<w:p/>") || paraXML.contains("<w:p />") {
            return #"<w:p><w:r><w:t xml:space="preserve">\#(escapeXML(safeText))</w:t></w:r></w:p>"#
        }

        // Preserve the original `<w:p ... attrs>` opening tag verbatim.
        // Word / Google sometimes reject paragraphs that lose their
        // `w14:paraId` or `w:rsidR` attributes, so we never rebuild the
        // tag from scratch — only rewrite what's BETWEEN it and `</w:p>`.
        guard let pOpenStart = paraXML.range(of: "<w:p"),
              let pOpenEnd   = paraXML.range(of: ">", range: pOpenStart.upperBound..<paraXML.endIndex),
              let pCloseStart = paraXML.range(of: "</w:p>", range: pOpenEnd.upperBound..<paraXML.endIndex)
        else {
            // Couldn't locate the paragraph boundaries — play it safe and
            // emit a minimal paragraph rather than a broken one.
            return #"<w:p><w:r><w:t xml:space="preserve">\#(escapeXML(safeText))</w:t></w:r></w:p>"#
        }
        let openingTag = String(paraXML[pOpenStart.lowerBound..<pOpenEnd.upperBound])
        let body       = String(paraXML[pOpenEnd.upperBound..<pCloseStart.lowerBound])

        // Extract pPr from the body (always the first child of <w:p> by spec).
        let pPr = substring(of: body, between: "<w:pPr>", and: "</w:pPr>")
                    .map { "<w:pPr>\($0)</w:pPr>" } ?? ""
        // First run's rPr — inherit font, size, colour.
        let rPrInner = firstRunProperties(in: body)
        let rPr = rPrInner.map { "<w:rPr>\($0)</w:rPr>" } ?? ""
        // Preserve the original first run's opening tag (with its rsid
        // attrs) verbatim. Word otherwise rejects rewritten paragraphs
        // even though they're schema-valid.
        let runOpen = firstRunOpeningTag(in: body) ?? "<w:r>"

        let newRun = #"\#(runOpen)\#(rPr)<w:t xml:space="preserve">\#(escapeXML(safeText))</w:t></w:r>"#
        return openingTag + pPr + newRun + "</w:p>"
    }

    // MARK: - Marker-aware rewrite + surgical substring helpers

    /// True if `text` contains any of the inline format markers we recognise.
    fileprivate static func textContainsFormatMarkers(_ text: String) -> Bool {
        text.contains("[B]") || text.contains("[/B]")
            || text.contains("[I]") || text.contains("[/I]")
            || text.contains("[U]") || text.contains("[/U]")
    }

    /// Strip every `[B]/[I]/[U]` marker from a string, leaving plain text.
    /// Used when we have to fall back to a layout-preserving path that
    /// can't honour inline emphasis (inline-tab paragraphs, etc.).
    fileprivate static func stripFormatMarkers(_ text: String) -> String {
        var out = text
        for token in ["[B]", "[/B]", "[I]", "[/I]", "[U]", "[/U]"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        return out
    }

    /// Walk `<w:r>` siblings inside `paraXML`, detect bold/italic/underline
    /// on each, and emit the paragraph as plain text with `[B]…[/B]` /
    /// `[I]…[/I]` / `[U]…[/U]` wrappers around the formatted spans. The
    /// inverse of `parseMarkedSpans`.
    fileprivate static func markedRunText(in paraXML: String) -> String {
        let spans = runSpans(in: paraXML)
        var out = ""
        for (text, format) in spans {
            var wrapped = text
            // Order matters only for the inverse parse — wrap from inside
            // out so the open/close markers nest cleanly.
            if format.contains(.underline) { wrapped = "[U]\(wrapped)[/U]" }
            if format.contains(.italic)    { wrapped = "[I]\(wrapped)[/I]" }
            if format.contains(.bold)      { wrapped = "[B]\(wrapped)[/B]" }
            out += wrapped
        }
        return out
    }

    /// Concatenate text + per-run format from every `<w:r>` in the
    /// paragraph. Self-closing `<w:r/>` runs and runs with no `<w:t>`
    /// (e.g. pure `<w:tab/>`) are skipped — they're inline layout, not
    /// text content.
    fileprivate static func runSpans(in paraXML: String) -> [(text: String, format: RunFormat)] {
        var out: [(String, RunFormat)] = []
        var cursor = paraXML.startIndex
        guard let textRe = try? NSRegularExpression(
            pattern: #"<w:t\b[^>]*?>([\s\S]*?)</w:t>"#
        ) else { return out }
        while let rOpen = paraXML.range(of: #"<w:r[\s>/]"#,
                                        options: .regularExpression,
                                        range: cursor..<paraXML.endIndex) {
            let lastChar = paraXML[paraXML.index(before: rOpen.upperBound)]
            if lastChar == "/" {
                cursor = rOpen.upperBound
                continue
            }
            guard let rClose = paraXML.range(of: "</w:r>",
                                             range: rOpen.upperBound..<paraXML.endIndex)
            else { break }
            let runSlice = String(paraXML[rOpen.lowerBound..<rClose.upperBound])

            var format: RunFormat = []
            if let rPrInner = substring(of: runSlice, between: "<w:rPr>", and: "</w:rPr>") {
                if rPrInner.range(of: #"<w:b\b[^/]*/>"#, options: .regularExpression) != nil
                    || rPrInner.contains("<w:b/>") {
                    format.insert(.bold)
                }
                if rPrInner.range(of: #"<w:i\b[^/]*/>"#, options: .regularExpression) != nil
                    || rPrInner.contains("<w:i/>") {
                    format.insert(.italic)
                }
                if rPrInner.contains("<w:u/>")
                    || rPrInner.range(of: #"<w:u\b[^/]*/>"#, options: .regularExpression) != nil {
                    format.insert(.underline)
                }
            }

            var text = ""
            let ns = runSlice as NSString
            let matches = textRe.matches(in: runSlice,
                                         range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 2 {
                text += unescapeXML(ns.substring(with: m.range(at: 1)))
            }
            if !text.isEmpty { out.append((text, format)) }
            cursor = rClose.upperBound
        }
        return out
    }

    /// Parse `[B]/[I]/[U]` markers in `marked` into a list of (text,
    /// format) spans. Markers are tracked as a stack so nested wrappers
    /// (`[B][I]bold-italic[/I][/B]`) produce a single span with both
    /// flags. Unmatched markers degrade to literal text rather than
    /// dropping characters — a misformed AI response shouldn't lose text.
    fileprivate static func parseMarkedSpans(_ marked: String) -> [(text: String, format: RunFormat)] {
        var spans: [(String, RunFormat)] = []
        var buffer = ""
        var stack: [RunFormat] = []
        var current: RunFormat { stack.reduce(into: RunFormat()) { $0.formUnion($1) } }

        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append((buffer, current))
            buffer = ""
        }

        var i = marked.startIndex
        while i < marked.endIndex {
            if marked[i] == "[" {
                let tokens: [(String, RunFormat?)] = [
                    ("[B]", .bold), ("[I]", .italic), ("[U]", .underline),
                    ("[/B]", nil),  ("[/I]", nil),    ("[/U]", nil),
                ]
                var matched = false
                for (token, openFmt) in tokens {
                    if marked[i...].hasPrefix(token) {
                        flush()
                        if let f = openFmt {
                            stack.append(f)
                        } else {
                            // Closing — pop the matching open marker if any.
                            let closing: RunFormat = token == "[/B]" ? .bold
                                                    : token == "[/I]" ? .italic : .underline
                            if let last = stack.lastIndex(of: closing) {
                                stack.remove(at: last)
                            }
                        }
                        i = marked.index(i, offsetBy: token.count)
                        matched = true
                        break
                    }
                }
                if matched { continue }
            }
            buffer.append(marked[i])
            i = marked.index(after: i)
        }
        flush()
        return spans
    }

    /// Re-derive `[B]/[I]/[U]` markers for a markerless rewrite. Any
    /// formatted span from the original paragraph whose text survives
    /// (case-insensitively) in `newText` gets re-wrapped, so
    /// "Led [B]Python[/B] projects" rewritten as "Led Python and SQL
    /// analytics" keeps Python bold instead of collapsing the paragraph
    /// to a single plain run. Spans equal to the whole paragraph are
    /// skipped — uniform formatting already survives via the cloned
    /// first-run `<w:rPr>` baseline.
    fileprivate static func reapplyOriginalEmphasis(from paraXML: String,
                                                    to newText: String) -> String {
        let originalSpans = runSpans(in: paraXML)
        let totalLen = originalSpans.reduce(0) { $0 + $1.text.count }
        var marked = newText
        for (text, format) in originalSpans where !format.isEmpty {
            let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard phrase.count >= 2, phrase.count < totalLen else { continue }
            // Don't re-mark inside an already-marked region.
            guard !marked.contains("[B]\(phrase)"), !marked.contains("[I]\(phrase)"),
                  !marked.contains("[U]\(phrase)") else { continue }
            guard let r = marked.range(of: phrase, options: [.caseInsensitive]) else { continue }
            var open = "", close = ""
            if format.contains(.bold)      { open += "[B]"; close = "[/B]" + close }
            if format.contains(.italic)    { open += "[I]"; close = "[/I]" + close }
            if format.contains(.underline) { open += "[U]"; close = "[/U]" + close }
            marked = marked.replacingCharacters(in: r, with: open + marked[r] + close)
        }
        return marked
    }

    /// Rewrite a paragraph's body from a marker-tagged `marked` string —
    /// preserves `<w:pPr>`, clones the first run's `<w:rPr>` as the
    /// baseline (font / size / colour), then emits one run per span with
    /// `<w:b/>` / `<w:i/>` / `<w:u w:val="single"/>` added or removed to
    /// match the span's format. Falls back to `rewriteParagraphText` when
    /// the parsed spans are empty or markerless.
    fileprivate static func rewriteParagraphMarked(_ paraXML: String,
                                                   marked: String) -> String {
        let spans = parseMarkedSpans(marked)
        let plainConcat = spans.map { $0.text }.joined()
        if spans.isEmpty {
            return rewriteParagraphText(paraXML, to: stripFormatMarkers(marked))
        }
        let allUnformatted = spans.allSatisfy { $0.format.isEmpty }
        if allUnformatted {
            return rewriteParagraphText(paraXML, to: plainConcat)
        }

        guard let pOpenStart = paraXML.range(of: "<w:p"),
              let pOpenEnd   = paraXML.range(of: ">", range: pOpenStart.upperBound..<paraXML.endIndex),
              let pCloseStart = paraXML.range(of: "</w:p>", range: pOpenEnd.upperBound..<paraXML.endIndex)
        else {
            return rewriteParagraphText(paraXML, to: plainConcat)
        }
        let openingTag = String(paraXML[pOpenStart.lowerBound..<pOpenEnd.upperBound])
        let body       = String(paraXML[pOpenEnd.upperBound..<pCloseStart.lowerBound])

        let pPr = substring(of: body, between: "<w:pPr>", and: "</w:pPr>")
                    .map { "<w:pPr>\($0)</w:pPr>" } ?? ""
        let baselineRPr = firstRunProperties(in: body) ?? ""
        let runOpen = firstRunOpeningTag(in: body) ?? "<w:r>"

        var runs = ""
        for (text, format) in spans {
            let safeText = stripInvalidXMLChars(text)
            let merged   = mergeRunFormat(into: baselineRPr, format: format)
            let rPr      = merged.isEmpty ? "" : "<w:rPr>\(merged)</w:rPr>"
            runs += #"\#(runOpen)\#(rPr)<w:t xml:space="preserve">\#(escapeXML(safeText))</w:t></w:r>"#
        }
        return openingTag + pPr + runs + "</w:p>"
    }

    /// Add or remove `<w:b/>` / `<w:i/>` / `<w:u w:val="single"/>` inside
    /// an existing `<w:rPr>` body so the resulting run carries the
    /// requested `RunFormat`. Strips any existing b/i/u first so toggling
    /// off works as well as toggling on.
    fileprivate static func mergeRunFormat(into rPrInner: String,
                                           format: RunFormat) -> String {
        var out = rPrInner
        out = out.replacingOccurrences(of: #"<w:b\b[^/]*/>"#, with: "",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: #"<w:i\b[^/]*/>"#, with: "",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: #"<w:u\b[^/]*/>"#, with: "",
                                       options: .regularExpression)
        // Per OOXML, b/i/u live near the front of rPr. Prepend any
        // requested ones so they win the cascade when Word renders.
        var prefix = ""
        if format.contains(.bold)      { prefix += "<w:b/>" }
        if format.contains(.italic)    { prefix += "<w:i/>" }
        if format.contains(.underline) { prefix += "<w:u w:val=\"single\"/>" }
        return prefix + out
    }

    /// Surgical substring replacement: for each (old, new) pair, find a
    /// `<w:t>` whose unescaped inner text contains `old` and swap only
    /// that substring inside the matching element. Run structure
    /// (siblings, `<w:rPr>`, hyperlinks, tabs) survives byte-for-byte.
    ///
    /// Constraints:
    /// - `old` must live entirely inside one `<w:t>`. Cross-run matches
    ///   are reported as `missed` so the caller can fall back to a full
    ///   rewrite rather than silently no-op.
    /// - Date-shaped text (`looksLikeDateSpan`) is skipped. The model
    ///   shouldn't be touching dates with surgical edits anyway, but
    ///   guarding here keeps a misclassified `old` from rewriting the
    ///   year on a role header.
    /// - Each (old, new) tries every text node in order; the first match
    ///   wins so repeated phrases don't all swap at once.
    fileprivate static func applySubstringReplacements(
        in paraXML: String,
        replacements: [(old: String, new: String)]
    ) -> (xml: String, applied: Int, missed: Int) {
        var xml = paraXML
        var applied = 0
        var missed  = 0
        for rep in replacements {
            let oldTrimmed = rep.old.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oldTrimmed.isEmpty else { missed += 1; continue }
            if replaceAcrossRuns(in: &xml, old: rep.old, new: rep.new) {
                applied += 1
            } else {
                missed += 1
            }
        }
        return (xml, applied, missed)
    }

    /// Replace the first occurrence of `old` with `new` across one OR MORE
    /// `<w:t>` runs in a paragraph, touching ONLY the text inside the runs.
    ///
    /// Why this matters: Word routinely splits a single visible phrase across
    /// several `<w:r>` runs (a bold keyword, a spell-check boundary, a font
    /// tweak). The old matcher searched each `<w:t>` in isolation, so any
    /// `old` text that straddled a run boundary was never found — the edit
    /// "missed" and the bullet fell through to a coarser whole-paragraph
    /// rewrite, which is what flattened formatting and reflowed the line.
    ///
    /// Here we concatenate the decoded text of every run, find `old` in that
    /// combined string, then write the change back into the run(s) it spans:
    /// `new` lands in the FIRST overlapped run (inheriting its formatting) and
    /// the matched remainder is removed from the following runs. `<w:rPr>` /
    /// `<w:pPr>` and the run structure are left byte-for-byte intact, so the
    /// résumé keeps its exact look — only the words change.
    private static func replaceAcrossRuns(in xml: inout String,
                                          old: String,
                                          new: String) -> Bool {
        guard let re = try? NSRegularExpression(
            pattern: #"<w:t\b[^>]*?>([\s\S]*?)</w:t>"#
        ) else { return false }

        let ns = xml as NSString
        let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return false }

        // One entry per `<w:t>`: the NSRange of its inner text (so we can
        // rewrite it in place) and the decoded characters it holds.
        struct Run { let innerRange: NSRange; let chars: [Character]; let plain: String }
        var runs: [Run] = []
        for m in matches where m.numberOfRanges >= 2 {
            let inner = m.range(at: 1)
            if inner.location == NSNotFound { continue }
            let plain = unescapeXML(ns.substring(with: inner))
            runs.append(Run(innerRange: inner, chars: Array(plain), plain: plain))
        }
        guard !runs.isEmpty else { return false }

        // Concatenate decoded text across runs; remember each run's start
        // offset (in Character units) into the combined string.
        var combinedChars: [Character] = []
        var runStart: [Int] = []
        for r in runs {
            runStart.append(combinedChars.count)
            combinedChars.append(contentsOf: r.chars)
        }
        let combined = String(combinedChars)

        guard let mr = combined.range(of: old) else { return false }
        let startOff = combined.distance(from: combined.startIndex, to: mr.lowerBound)
        let endOff   = combined.distance(from: combined.startIndex, to: mr.upperBound)

        // Compute the new inner text for each run the match overlaps. Bail if
        // the match touches a date-looking run — dates must stay byte-exact.
        var newInner: [Int: String] = [:]
        var placedNew = false
        for (i, r) in runs.enumerated() {
            let rs   = runStart[i]
            let rEnd = rs + r.chars.count
            let lo = max(rs, startOff)
            let hi = min(rEnd, endOff)
            guard lo < hi else { continue }                 // run not overlapped
            if looksLikeDateSpan(r.plain) { return false }
            let prefix = String(r.chars[0..<(lo - rs)])
            let suffix = String(r.chars[(hi - rs)..<r.chars.count])
            if !placedNew {
                newInner[i] = prefix + new + suffix          // new text lands here
                placedNew = true
            } else {
                newInner[i] = prefix + suffix                // matched remainder removed
            }
        }
        guard placedNew else { return false }

        // Apply highest run index first so the earlier runs' NSRanges (which
        // were computed against the original string) stay valid as we edit.
        for i in newInner.keys.sorted(by: >) {
            let escaped = escapeXML(stripInvalidXMLChars(newInner[i]!))
            xml = (xml as NSString)
                .replacingCharacters(in: runs[i].innerRange, with: escaped) as String
        }
        return true
    }

    // MARK: - Table row insertion

    /// Count `<w:tr ...>` row-opening tags inside `s`. Rows never nest in
    /// OOXML, so the count is also the 0-based "row index" of the row
    /// that opens immediately after this prefix.
    fileprivate static func countTrOpens(in s: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"<w:tr[\s/>]"#)
        else { return 0 }
        return re.numberOfMatches(in: s,
                                  range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Given a paragraph at `refIndex0` (0-based into `paragraphs`),
    /// return the 0-based paragraph indices of the FIRST and LAST
    /// paragraphs of the table row that encloses it. Returns nil if the
    /// paragraph is not inside a `<w:tr>`.
    ///
    /// Detection works by tracking row depth across gaps: gaps[i] sits
    /// between paragraphs[i-1] and paragraphs[i]. Walk forward from the
    /// reference paragraph, accumulating `(opens − closes)` per gap;
    /// when depth crosses zero we've left the row. Walk backward the
    /// same way to find the row's opening.
    fileprivate static func locateEnclosingRow(refIndex0: Int,
                                               paragraphs: [String],
                                               gaps: [String])
    -> (firstIdx0: Int, lastIdx0: Int)? {
        guard refIndex0 >= 0, refIndex0 < paragraphs.count else { return nil }
        guard gaps.count >= paragraphs.count + 1 else { return nil }

        func opens(_ s: String) -> Int { countTrOpens(in: s) }
        func closes(_ s: String) -> Int {
            var n = 0
            var cur = s.startIndex
            while let r = s.range(of: "</w:tr>", range: cur..<s.endIndex) {
                n += 1
                cur = r.upperBound
            }
            return n
        }

        // Forward: find the gap that takes us out of the row.
        var depth = 1
        var lastIdx0 = refIndex0
        var i = refIndex0 + 1
        while i <= paragraphs.count {
            depth += opens(gaps[i]) - closes(gaps[i])
            if depth <= 0 {
                lastIdx0 = i - 1
                break
            }
            i += 1
        }
        if depth > 0 { return nil }

        // Backward: find the gap that opens our row.
        depth = 1
        var firstIdx0 = refIndex0
        var j = refIndex0
        while j >= 0 {
            depth -= opens(gaps[j]) - closes(gaps[j])
            if depth <= 0 {
                firstIdx0 = j
                break
            }
            j -= 1
        }
        if depth > 0 { return nil }

        return (firstIdx0, lastIdx0)
    }

    /// Reassemble the row that spans paragraphs `firstIdx0...lastIdx0`
    /// into a single XML string `<w:tr ...>…</w:tr>`. Slices the leading
    /// gap from the last `<w:tr>` opening (in case the gap also closes a
    /// previous row), walks paragraphs + interior gaps verbatim, and
    /// slices the trailing gap up to the first `</w:tr>` closing.
    fileprivate static func extractRowXML(firstIdx0: Int,
                                          lastIdx0: Int,
                                          paragraphs: [String],
                                          gaps: [String]) -> String? {
        guard firstIdx0 >= 0, lastIdx0 < paragraphs.count, firstIdx0 <= lastIdx0
        else { return nil }
        guard let leadOpen = gaps[firstIdx0].range(of: #"<w:tr[\s/>]"#,
                                                   options: [.regularExpression, .backwards])
        else { return nil }
        guard let trailClose = gaps[lastIdx0 + 1].range(of: "</w:tr>")
        else { return nil }

        var row = String(gaps[firstIdx0][leadOpen.lowerBound...])
        for i in firstIdx0...lastIdx0 {
            row += paragraphs[i]
            if i < lastIdx0 { row += gaps[i + 1] }
        }
        row += String(gaps[lastIdx0 + 1][..<trailClose.upperBound])
        return row
    }

    /// Clone a row's XML for insertion as a brand-new row right after the
    /// source. Strips the `w:rsid*` / `w14:paraId` identifiers that Word
    /// stamps on every paragraph (Google Docs rejects duplicates), then
    /// walks each `<w:p>...</w:p>` in source order and rewrites its text
    /// from the corresponding `cells[i]` via `cloneParagraphForInsert`.
    /// Paragraphs past `cells.count` keep their original text — handy if
    /// a column always carries a fixed label the new row should inherit.
    fileprivate static func cloneRowWithCells(_ rowXML: String,
                                              cells: [String]) -> String {
        var clone = rowXML
        let idAttrPatterns = [
            #"\s+w14:paraId="[^"]*""#,
            #"\s+w14:textId="[^"]*""#,
            #"\s+w:rsidR="[^"]*""#,
            #"\s+w:rsidRDefault="[^"]*""#,
            #"\s+w:rsidP="[^"]*""#,
            #"\s+w:rsidTr="[^"]*""#,
        ]
        for pattern in idAttrPatterns {
            clone = clone.replacingOccurrences(of: pattern, with: "",
                                               options: .regularExpression)
        }

        var result = ""
        var cellIndex = 0
        var cursor = clone.startIndex
        while let pOpen = clone.range(of: #"<w:p[\s/>]"#,
                                      options: .regularExpression,
                                      range: cursor..<clone.endIndex) {
            guard let pClose = clone.range(of: "</w:p>",
                                           range: pOpen.upperBound..<clone.endIndex)
            else { break }
            result += String(clone[cursor..<pOpen.lowerBound])
            let pXML = String(clone[pOpen.lowerBound..<pClose.upperBound])
            if cellIndex < cells.count {
                let trimmed = cells[cellIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty cell value → keep the source paragraph's text rather
                // than wiping it, so the model can leave a column alone
                // by passing "" without zeroing the cloned content.
                if trimmed.isEmpty {
                    result += pXML
                } else {
                    result += cloneParagraphForInsert(pXML, to: cells[cellIndex])
                }
            } else {
                result += pXML
            }
            cellIndex += 1
            cursor = pClose.upperBound
        }
        result += String(clone[cursor...])
        return result
    }

    /// Find the `rowIndex0`-th `<w:tr>` opening tag in `xml` (0-based,
    /// counting in document order), walk to its matching `</w:tr>`, and
    /// inject `newRow` right after the close. Returns nil if the row
    /// can't be located.
    fileprivate static func injectRowAfter(rowIndex0: Int,
                                           newRow: String,
                                           in xml: String) -> String? {
        var count = 0
        var cursor = xml.startIndex
        var targetOpen: Range<String.Index>?
        while let r = xml.range(of: #"<w:tr[\s/>]"#,
                                options: .regularExpression,
                                range: cursor..<xml.endIndex) {
            if count == rowIndex0 {
                targetOpen = r
                break
            }
            count += 1
            cursor = r.upperBound
        }
        guard let openR = targetOpen else { return nil }
        guard let closeR = xml.range(of: "</w:tr>",
                                     range: openR.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[..<closeR.upperBound]) + newRow + String(xml[closeR.upperBound...])
    }

    /// Drop characters that XML 1.0 forbids. Keeps tab (0x09), LF (0x0A),
    /// CR (0x0D) and everything ≥ 0x20. Other C0 controls slip in when
    /// a model pastes junk from the training data or accidentally emits
    /// form-feed / vertical-tab inside bullet text; those break Word's
    /// schema validation even though our validator may wave them through.
    fileprivate static func stripInvalidXMLChars(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { out.unicodeScalars.append(scalar); continue }
            if v < 0x20 { continue }                      // forbidden C0 controls
            if v >= 0x7F && v <= 0x84 { continue }        // DEL + C1 controls subset
            if v >= 0x86 && v <= 0x9F { continue }        // rest of C1 controls
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Re-pack the contents of `tempDir` into a `.docx` at `outputURL`.
    ///
    /// Two strict-reader correctness requirements that the naive
    /// `zip -r -X .` invocation misses:
    /// 1. ECMA-376 requires `[Content_Types].xml` to be the FIRST entry
    ///    in the archive so it can be read without scanning the central
    ///    directory. Google Docs enforces this; Word doesn't.
    /// 2. Hidden / OS-junk files (`.DS_Store`, `__MACOSX/`, AppleDouble
    ///    `._*` files) must not be in the archive — Google Docs treats
    ///    their presence as a malformed package.
    ///
    /// We do this in two passes: first zip ONLY `[Content_Types].xml`, then
    /// append everything else with a recursive call that excludes the
    /// already-added file and hidden cruft.
    fileprivate static func repackDOCX(from tempDir: URL,
                                       to outputURL: URL) throws {
        let fm = FileManager.default
        // Strip macOS metadata so it never lands in the package.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        cleanup.currentDirectoryURL = tempDir
        cleanup.arguments = [".",
                             "-name", ".DS_Store", "-delete",
                             "-o", "-name", "._*", "-delete"]
        try? cleanup.run()
        cleanup.waitUntilExit()

        // Pass 1: write `[Content_Types].xml` as the first entry.
        // `-D` suppresses directory entries; `-X` strips extra fields.
        let pass1 = Process()
        pass1.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        pass1.currentDirectoryURL = tempDir
        pass1.arguments = ["-X", "-D", outputURL.path, "[Content_Types].xml"]
        try pass1.run()
        pass1.waitUntilExit()
        guard pass1.terminationStatus == 0 else { throw DOCXError.zipFailed }

        // Pass 2: append the remaining top-level entries.
        //
        // We deliberately AVOID zip's `-x` exclude flag for `[Content_Types].xml`
        // because zip's pattern parser treats `[...]` as a character class —
        // `-x "[Content_Types].xml"` matches single-char filenames like
        // `C.xml`/`o.xml`, NOT the literal `[Content_Types].xml`. Earlier
        // attempts to backslash-escape the brackets weren't reliably
        // honoured by BSD zip on macOS, so pass 2 kept re-adding the file
        // and moving it from entry 0 to the end of the archive. Google Docs
        // requires the content-types map to be the first entry, so it
        // rejected every output.
        //
        // Solution: enumerate the top-level entries with FileManager,
        // filter out `[Content_Types].xml` and OS junk explicitly, and pass
        // each remaining name as a positional argument. `zip -r` recurses
        // into subdirectories on its own.
        let topLevel = (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let entriesToAdd = topLevel
            .map { $0.lastPathComponent }
            .filter { $0 != "[Content_Types].xml" && $0 != "__MACOSX" }
        guard !entriesToAdd.isEmpty else { return }

        let pass2 = Process()
        pass2.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        pass2.currentDirectoryURL = tempDir
        // -D suppresses directory entries (size-0 records like `docProps/`)
        // that some validators (Google Docs included) treat as malformed
        // when the spec doesn't require them.
        pass2.arguments = ["-r", "-X", "-D", outputURL.path] + entriesToAdd
        try pass2.run()
        pass2.waitUntilExit()
        guard pass2.terminationStatus == 0,
              fm.fileExists(atPath: outputURL.path) else {
            throw DOCXError.zipFailed
        }
    }

    /// Clone a template paragraph for INSERTION, stripping the unique-ID
    /// attributes that Word stamps on every `<w:p>`. Without stripping,
    /// two paragraphs would share the same `w14:paraId`, and Google Docs
    /// will reject the upload with a "not a valid document" error. Word
    /// tolerates duplicates but the file becomes subtly broken over time.
    fileprivate static func cloneParagraphForInsert(_ paraXML: String, to newText: String) -> String {
        // Start from the standard rewrite (which preserves pPr + first-run
        // rPr and only swaps text) then strip the identifier attributes
        // from the outer `<w:p ...>` tag so the new paragraph gets implicit
        // fresh IDs when Word reopens the file.
        let rewritten = rewriteParagraphText(paraXML, to: newText)
        guard let pOpenStart = rewritten.range(of: "<w:p"),
              let pOpenEnd   = rewritten.range(of: ">", range: pOpenStart.upperBound..<rewritten.endIndex)
        else { return rewritten }

        var openingTag = String(rewritten[pOpenStart.lowerBound..<pOpenEnd.upperBound])
        // Attributes Word uses as unique identifiers per-paragraph. Remove
        // all of them; Word regenerates as needed on next save.
        let idAttrPatterns = [
            #"\s+w14:paraId="[^"]*""#,
            #"\s+w14:textId="[^"]*""#,
            #"\s+w:rsidR="[^"]*""#,
            #"\s+w:rsidRDefault="[^"]*""#,
            #"\s+w:rsidP="[^"]*""#,
            #"\s+w:rsidTr="[^"]*""#,
        ]
        for pattern in idAttrPatterns {
            openingTag = openingTag.replacingOccurrences(of: pattern, with: "",
                                                        options: .regularExpression)
        }
        return String(rewritten[..<pOpenStart.lowerBound])
             + openingTag
             + String(rewritten[pOpenEnd.upperBound...])
    }

    private static func firstRunProperties(in paraXML: String) -> String? {
        var cursor = paraXML.startIndex
        while let rOpen = paraXML.range(of: #"<w:r[\s>/]"#,
                                        options: .regularExpression,
                                        range: cursor..<paraXML.endIndex) {
            guard let rClose = paraXML.range(of: "</w:r>", range: rOpen.upperBound..<paraXML.endIndex)
            else { break }
            let runSlice = String(paraXML[rOpen.lowerBound..<rClose.upperBound])
            if let inner = substring(of: runSlice, between: "<w:rPr>", and: "</w:rPr>") {
                return inner
            }
            cursor = rClose.upperBound
        }
        return nil
    }

    /// Return the first `<w:r ...>` opening tag verbatim (with all of its
    /// `w:rsidR` / `w:rsidDel` / `w:rsidRPr` metadata). Word treats runs
    /// without these attributes as foreign-tooling output and is pickier
    /// about validating them; preserving the original run's opening tag
    /// makes our rewritten paragraphs look identical at the metadata
    /// level. Skips false positives like `<w:rPr>`, `<w:rFonts>` (the
    /// regex `[\s>/]` requirement excludes any letter immediately after
    /// `<w:r`) and self-closing `<w:r/>` runs.
    private static func firstRunOpeningTag(in paraXML: String) -> String? {
        var cursor = paraXML.startIndex
        while let openMatch = paraXML.range(of: #"<w:r[\s>/]"#,
                                            options: .regularExpression,
                                            range: cursor..<paraXML.endIndex) {
            // Skip self-closing `<w:r/>` runs — they have no content to
            // anchor a rewrite against.
            let lastChar = paraXML[paraXML.index(before: openMatch.upperBound)]
            if lastChar == "/" {
                cursor = openMatch.upperBound
                continue
            }
            // The match is `<w:r>` (5 chars including `>`) or `<w:r ` /
            // `<w:r/`. Walk forward to the `>` that closes the opening tag.
            let scanStart = paraXML.index(before: openMatch.upperBound)
            guard let gt = paraXML.range(of: ">", range: scanStart..<paraXML.endIndex) else {
                return nil
            }
            return String(paraXML[openMatch.lowerBound..<gt.upperBound])
        }
        return nil
    }

    /// Split body into paragraph blocks and the gaps between them.
    private static func splitBodySegments(_ body: String) -> ([String], [String]) {
        var paras: [String] = []
        var gaps: [String] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            // CRITICAL: anchor the match to a REAL paragraph opening tag —
            // `<w:p` followed by whitespace, `/`, or `>`. The previous
            // approach searched for the bare prefix `<w:p` and tried to
            // skip when followed by a letter; the skip path advanced the
            // cursor 4 chars past `<w:p`, dropping those bytes from the
            // body. That silently corrupted any `<w:p…>` element whose
            // name didn't match a paragraph (like `<w:pgNumType>` inside
            // `<w:sectPr>` or `<w:pBdr>` / `<w:pageBreakBefore>` inside
            // `<w:pPr>`), producing torn XML in the output document.
            guard let open = body.range(of: #"<w:p[\s/>]"#,
                                        options: .regularExpression,
                                        range: cursor..<body.endIndex) else {
                gaps.append(String(body[cursor...]))
                break
            }
            gaps.append(String(body[cursor..<open.lowerBound]))

            // The regex match consumed the terminator char (the `[\s/>]`).
            // Step one back so attribute/closing-tag scanning starts AT
            // that terminator — necessary when it's `>` itself.
            let scanStart = body.index(before: open.upperBound)
            guard let firstGT = body.range(of: ">", range: scanStart..<body.endIndex) else {
                break
            }
            let openTagEnd = firstGT.upperBound
            // Self-closing iff the char immediately before that `>` is `/`.
            // Only the paragraph's own tag can be self-closed; nested
            // `<w:br/>` / `<w:tab/>` are caught by the regex anchor above.
            if firstGT.lowerBound > body.startIndex,
               body[body.index(before: firstGT.lowerBound)] == "/" {
                paras.append(String(body[open.lowerBound..<openTagEnd]))
                cursor = openTagEnd
                continue
            }
            // Normal paragraph: capture up through `</w:p>`.
            guard let paraEnd = body.range(of: "</w:p>", range: openTagEnd..<body.endIndex) else {
                break
            }
            let end = paraEnd.upperBound
            paras.append(String(body[open.lowerBound..<end]))
            cursor = end
        }
        if gaps.count == paras.count { gaps.append("") }
        return (paras, gaps)
    }

    /// Concatenate every `<w:t>` in a paragraph to its plain-text form.
    private static func concatRunText(in paraXML: String) -> String {
        var out = ""
        var cursor = paraXML.startIndex
        while cursor < paraXML.endIndex {
            guard let open = paraXML.range(of: "<w:t", range: cursor..<paraXML.endIndex) else { break }
            let after = open.upperBound
            if after < paraXML.endIndex, paraXML[after].isLetter {
                cursor = after
                continue
            }
            guard let gt = paraXML.range(of: ">", range: after..<paraXML.endIndex) else { break }
            if paraXML[paraXML.index(before: gt.lowerBound)] == "/" {
                cursor = gt.upperBound
                continue
            }
            guard let close = paraXML.range(of: "</w:t>", range: gt.upperBound..<paraXML.endIndex) else { break }
            out += unescapeXML(String(paraXML[gt.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return out
    }

    /// Find the index of the LAST bullet paragraph that belongs to a given
    /// employer. Heuristic:
    /// 1. Find the first paragraph whose text contains the employer name
    ///    (case-insensitive).
    /// 2. Walk forward, tracking paragraphs that have `<w:numPr>` (list items).
    ///    Stop as soon as we see a non-list paragraph AFTER at least one
    ///    list paragraph — that's the next section's header.
    /// 3. Return the index of the last list paragraph we saw.
    private static func findLastBullet(forEmployer employer: String,
                                       in paragraphs: [String]) -> Int? {
        let needle = employer.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        guard let empIdx = paragraphs.firstIndex(where: {
            concatRunText(in: $0).range(of: needle, options: .caseInsensitive) != nil
        }) else { return nil }

        var lastBullet: Int? = nil
        var i = empIdx + 1
        while i < paragraphs.count {
            let isBullet = paragraphs[i].contains("<w:numPr>")
            if isBullet {
                lastBullet = i
            } else if lastBullet != nil {
                // Reached the next section once we've already seen bullets.
                let txt = concatRunText(in: paragraphs[i]).trimmingCharacters(in: .whitespaces)
                if !txt.isEmpty { break }
            }
            i += 1
        }
        return lastBullet
    }

    /// Normalise text for fuzzy-exact matching: collapse whitespace,
    /// lowercase. The AI often returns bullet text with small whitespace
    /// variations; this makes the match robust without being so loose it
    /// mis-hits a different bullet.
    private static func normaliseForMatch(_ s: String) -> String {
        let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    private static func substring(of s: String, between a: String, and b: String) -> String? {
        guard let ra = s.range(of: a),
              let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return nil }
        return String(s[ra.upperBound..<rb.lowerBound])
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;",  with: "&")
    }

    /// Convert the most common non-XML entity references into forms that
    /// pass Foundation's strict parser: HTML-named entities become their
    /// Unicode numeric equivalents, and bare `&` characters that aren't
    /// already opening a valid entity reference get escaped to `&amp;`.
    ///
    /// Why: Claude (especially Haiku) occasionally types `&nbsp;`, `&mdash;`,
    /// or a stray `&` directly inside a `<w:t>`. Word opens those files
    /// without complaint, but `XMLParser` rejects them as undeclared
    /// entity references (NSXMLParserErrorDomain 111). Sanitizing first
    /// keeps output strictly valid without altering visible content.
    static func sanitizeXMLEntities(_ xml: String) -> String {
        var out = xml
        // Common HTML entities → numeric character references.
        let htmlEntities: [(String, String)] = [
            ("&nbsp;",   "&#160;"),
            ("&mdash;",  "&#8212;"),
            ("&ndash;",  "&#8211;"),
            ("&hellip;", "&#8230;"),
            ("&lsquo;",  "&#8216;"),
            ("&rsquo;",  "&#8217;"),
            ("&ldquo;",  "&#8220;"),
            ("&rdquo;",  "&#8221;"),
            ("&trade;",  "&#8482;"),
            ("&copy;",   "&#169;"),
            ("&reg;",    "&#174;"),
            ("&euro;",   "&#8364;"),
            ("&bull;",   "&#8226;"),
            ("&middot;", "&#183;"),
            ("&deg;",    "&#176;"),
            ("&laquo;",  "&#171;"),
            ("&raquo;",  "&#187;"),
        ]
        for (from, to) in htmlEntities {
            out = out.replacingOccurrences(of: from, with: to)
        }
        // Escape any remaining bare `&`: match `&` NOT followed by
        // amp/lt/gt/quot/apos/#NNN/#xHHH and a semicolon.
        let strayAmp = #"&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)"#
        if let re = try? NSRegularExpression(pattern: strayAmp) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "&amp;")
        }
        return out
    }

    /// Write an arbitrary (already-modified) `document.xml` string back into
    /// a DOCX. Validates XML well-formedness first and re-zips. Used by the
    /// agent-mode flow that applies many incremental str_replaces outside
    /// this class before committing the final result.
    ///
    /// `outputFilename`, if provided, is the basename used for the emitted
    /// .docx (including extension). When nil, a unique temp name is chosen.
    static func writeDocumentXML(_ xml: String,
                                 originalBytes: Data,
                                 outputFilename: String? = nil) throws -> URL {
        // Auto-sanitize first: Claude sometimes emits `&nbsp;` / `&mdash;` /
        // bare `&` which Word would open fine but our strict validator
        // rejects. Normalise to numeric char refs / escape bare ampersands.
        let sanitized = Self.sanitizeXMLEntities(xml)
        // Strict parser is advisory only here — Word is more tolerant, and
        // rejecting a file the user might've opened fine is a worse failure
        // mode than surfacing a warning and letting them inspect.
        if let data = sanitized.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            _ = parser.parse()
        }
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let docURL = tempDir.appendingPathComponent("word/document.xml")
        try sanitized.write(to: docURL, atomically: true, encoding: .utf8)

        let outputURL = try uniqueOutputURL(filename: outputFilename)
        try Self.repackDOCX(from: tempDir, to: outputURL)
        return outputURL
    }

    /// Build a fresh output URL in the temp directory, using `filename` when
    /// provided. Guarantees uniqueness by prefixing with a UUID sub-folder
    /// so repeated saves of the same-named file don't collide.
    private static func uniqueOutputURL(filename: String?) throws -> URL {
        let fm = FileManager.default
        let bucket = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        let chosen = (filename?.isEmpty == false ? filename! :
                      "resume_\(Int(Date().timeIntervalSince1970)).docx")
        return bucket.appendingPathComponent(chosen)
    }

    // MARK: - Internals

    /// XMLParser delegate that only records the first parse error. We don't
    /// need structural info — just a yes/no on whether the document still
    /// parses after the AI's edits.
    private final class WellFormednessChecker: NSObject, XMLParserDelegate {
        var firstError: String?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if firstError == nil { firstError = parseError.localizedDescription }
        }
    }

    private static func unzip(_ data: Data) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let src = tempDir.appendingPathComponent("src.docx")
        try data.write(to: src)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", src.path, "-d", tempDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? fm.removeItem(at: src)
        guard unzip.terminationStatus == 0 else { throw DOCXError.unreadable }
        return tempDir
    }
}
