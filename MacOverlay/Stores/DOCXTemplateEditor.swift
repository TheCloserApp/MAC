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

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-r", "-X", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, fm.fileExists(atPath: outputURL.path) else {
            throw DOCXError.zipFailed
        }
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
            let injected = rewriteParagraphText(template, to: add.text)
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

        // Validate & repack — same safety net as the other flows.
        if let data = xml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            if !parser.parse() {
                let err = parser.parserError?.localizedDescription
                       ?? delegate.firstError ?? "malformed XML"
                throw DOCXError.invalidXMLAfterEdits(detail: err)
            }
        }
        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("resume_\(Int(Date().timeIntervalSince1970)).docx")
        try? fm.removeItem(at: outputURL)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-r", "-X", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, fm.fileExists(atPath: outputURL.path) else {
            throw DOCXError.zipFailed
        }
        return GapApplyOutcome(
            url: outputURL,
            rewritesApplied: rewritesApplied,
            rewritesMissed: rewritesMissed,
            bulletsAdded: bulletsAdded,
            bulletsMissed: bulletsMissed
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
        guard let bs = xml.range(of: "<w:body>"),
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
        // Empty paragraph → nothing to replace against. Fall back to
        // injecting a single plain run with the new text.
        if paraXML.contains("<w:p/>") || paraXML.hasSuffix("<w:p />") {
            return #"<w:p><w:r><w:t xml:space="preserve">\#(escapeXML(newText))</w:t></w:r></w:p>"#
        }

        let pPr = substring(of: paraXML, between: "<w:pPr>", and: "</w:pPr>")
                    .map { "<w:pPr>\($0)</w:pPr>" } ?? ""

        // First run's rPr — inherit font, size, colour.
        let rPrInner = firstRunProperties(in: paraXML)
        let rPr = rPrInner.map { "<w:rPr>\($0)</w:rPr>" } ?? ""

        let newRun = #"<w:r>\#(rPr)<w:t xml:space="preserve">\#(escapeXML(newText))</w:t></w:r>"#
        return "<w:p>\(pPr)\(newRun)</w:p>"
    }

    private static func firstRunProperties(in paraXML: String) -> String? {
        var cursor = paraXML.startIndex
        while let rOpen = paraXML.range(of: "<w:r>", range: cursor..<paraXML.endIndex)
                         ?? paraXML.range(of: "<w:r ", range: cursor..<paraXML.endIndex) {
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

    /// Split body into paragraph blocks and the gaps between them.
    private static func splitBodySegments(_ body: String) -> ([String], [String]) {
        var paras: [String] = []
        var gaps: [String] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let open = body.range(of: "<w:p", range: cursor..<body.endIndex) else {
                gaps.append(String(body[cursor...]))
                break
            }
            let afterTag = open.upperBound
            if afterTag < body.endIndex, body[afterTag] == "P" {
                cursor = afterTag
                continue
            }
            gaps.append(String(body[cursor..<open.lowerBound]))
            let selfClose = body.range(of: "/>", range: afterTag..<body.endIndex)
            let paraEnd   = body.range(of: "</w:p>", range: afterTag..<body.endIndex)
            if let sc = selfClose, let pe = paraEnd, sc.lowerBound < pe.lowerBound {
                let end = sc.upperBound
                paras.append(String(body[open.lowerBound..<end]))
                cursor = end
            } else if let pe = paraEnd {
                let end = pe.upperBound
                paras.append(String(body[open.lowerBound..<end]))
                cursor = end
            } else {
                break
            }
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
        if let data = xml.data(using: .utf8) {
            let parser = XMLParser(data: data)
            let delegate = WellFormednessChecker()
            parser.delegate = delegate
            if !parser.parse() {
                let err = parser.parserError?.localizedDescription
                       ?? delegate.firstError ?? "malformed XML"
                throw DOCXError.invalidXMLAfterEdits(detail: err)
            }
        }
        let tempDir = try unzip(originalBytes)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let docURL = tempDir.appendingPathComponent("word/document.xml")
        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        let outputURL = try uniqueOutputURL(filename: outputFilename)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-r", "-X", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw DOCXError.zipFailed
        }
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
