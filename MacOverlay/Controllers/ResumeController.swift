import Foundation
import AppKit

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

        Task { [weak vm] in
            do {
                let raw = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey:       apiKeyCopy,
                    openAIApiKey: openAIKeyCopy,
                    model:        "claude-haiku-4-5-20251001",
                    screenshot:   nil,
                    systemPrompt: "You are an ATS and resume expert. Always respond in the exact format requested."
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
    func generate() {
        guard let vm else { return }
        let base = vm.currentResumeText
        guard !vm.resumeJD.isEmpty, !base.isEmpty, !vm.apiKey.isEmpty else { return }

        vm.isGeneratingResume = true
        vm.resumeOutput       = ""
        vm.resumeFileURL      = nil

        let jd = vm.resumeJD
        let prompt = """
        Job Description:
        \(jd)

        Current Resume:
        \(base)

        Write a tailored, ATS-optimised resume for this role. Rules:
        - Use only information from the provided resume — invent nothing.
        - Use keywords from the job description.
        - Section headings must be ALL CAPS on their own line (e.g. SUMMARY, EXPERIENCE, EDUCATION, SKILLS).
        - Bullet points must start with "- ".
        - No markdown, no asterisks, no symbols except dashes for bullets.
        - Output plain text only.
        """

        let apiKeyCopy = vm.apiKey
        let openAIKeyCopy = vm.openAIApiKey

        Task { [weak vm] in
            do {
                let result = try await AIManager.shared.sendMessage(
                    prompt,
                    apiKey:       apiKeyCopy,
                    openAIApiKey: openAIKeyCopy,
                    model:        "claude-haiku-4-5-20251001",
                    screenshot:   nil,
                    systemPrompt: "You are an expert resume writer. Output clean plain text with ALL CAPS section headings and '- ' bullet points. No markdown."
                )
                vm?.resumeOutput  = result
                vm?.resumeFileURL = try Self.saveDOCX(text: result)
            } catch {
                vm?.resumeOutput = "Error: \(error.localizedDescription)"
            }
            vm?.isGeneratingResume = false
        }
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
