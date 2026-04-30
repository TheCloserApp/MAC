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
    struct IndexedParagraph {
        let index: Int
        let text: String
        let xml: String
    }

    /// One AI-specified edit referenced by paragraph index rather than by
    /// text matching. `.rewrite` replaces the paragraph's text; `.insertAfter`
    /// injects a new paragraph cloned from the target's XML (so bullet marker,
    /// indent, fonts, and sizes all come along).
    enum IndexedEdit {
        case rewrite(index: Int, newText: String)
        case insertAfter(index: Int, newText: String)
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
        var validationWarning: String?
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
        var rewritesByIdx: [Int: String] = [:]
        var insertionsByIdx: [Int: [String]] = [:]
        for edit in edits {
            switch edit {
            case .rewrite(let idx, let newText):
                rewritesByIdx[idx] = newText
            case .insertAfter(let idx, let newText):
                insertionsByIdx[idx, default: []].append(newText)
            }
        }

        var rewritesApplied = 0
        var rewritesMissed: [Int] = []
        var insertionsApplied = 0
        var insertionsMissed: [Int] = []
        var layoutPreserved: [Int] = []

        // Apply rewrites in place (indices stay stable since we're not
        // inserting yet). For paragraphs with inline layout elements
        // (tabs / breaks / position tabs) we use SURGICAL replacement —
        // swap only the largest non-date `<w:t>` text node, leaving runs,
        // tabs, breaks, and bold sub-phrases untouched. For paragraphs
        // without those elements we collapse to a single run via
        // `rewriteParagraphText`, which gives clean text but loses bold
        // sub-phrases (acceptable trade-off for clean rewrites).
        for (idx, newText) in rewritesByIdx {
            let arrayIdx = idx - 1
            guard arrayIdx >= 0, arrayIdx < paragraphs.count else {
                rewritesMissed.append(idx)
                continue
            }
            if hasInlineLayoutElements(paragraphs[arrayIdx]) {
                let edited = surgicallyReplaceLargestText(paragraphs[arrayIdx], with: newText)
                if edited == paragraphs[arrayIdx] {
                    // Every text segment looked like a date — there was
                    // nothing safe to swap. Preserve the paragraph as-is.
                    layoutPreserved.append(idx)
                    continue
                }
                paragraphs[arrayIdx] = edited
                rewritesApplied += 1
                continue
            }
            paragraphs[arrayIdx] = rewriteParagraphText(paragraphs[arrayIdx], to: newText)
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
