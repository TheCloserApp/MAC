//! Plain-text extraction from résumé / context files.
//!
//! Port of the macOS `ResumeImporter`: PDF, DOCX, RTF, TXT, and MD go in,
//! normalized plain text comes out. Everything here is pure Rust so it works
//! identically on Windows (the Mac version shelled out to `/usr/bin/unzip`
//! and leaned on PDFKit / NSAttributedString, neither of which exists there).

use std::path::Path;

/// Extensions we know how to read (lowercase, no dot).
pub const SUPPORTED_EXTENSIONS: [&str; 6] = ["pdf", "docx", "rtf", "txt", "md", "markdown"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportError {
    Unsupported(String),
    Unreadable(String),
    Empty,
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImportError::Unsupported(ext) => write!(f, "Unsupported file type: .{ext}"),
            ImportError::Unreadable(why) => write!(f, "Could not read file: {why}"),
            ImportError::Empty => write!(f, "File contained no text"),
        }
    }
}

impl std::error::Error for ImportError {}

/// Text plus, for a `.docx`, the original bytes — kept so a future generator
/// can rewrite paragraphs in place and preserve the document's styling.
pub struct Imported {
    pub text: String,
    pub original_docx: Option<Vec<u8>>,
}

/// Filename without extension, `_`/`-` turned into spaces, capped at 40 chars
/// — the default name for an uploaded résumé preset.
pub fn suggested_name(path: &Path) -> String {
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    stem.replace(['_', '-'], " ").chars().take(40).collect()
}

pub fn is_supported(path: &Path) -> bool {
    let ext = extension(path);
    SUPPORTED_EXTENSIONS.contains(&ext.as_str())
}

fn extension(path: &Path) -> String {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// Read `path` and extract its text.
pub fn import(path: &Path) -> Result<Imported, ImportError> {
    let ext = extension(path);
    let bytes = std::fs::read(path).map_err(|e| ImportError::Unreadable(e.to_string()))?;
    let (text, original_docx) = match ext.as_str() {
        "pdf" => (extract_pdf(&bytes)?, None),
        "docx" => (extract_docx(&bytes)?, Some(bytes.clone())),
        "rtf" => (extract_rtf(&decode_text(&bytes)), None),
        "txt" | "md" | "markdown" => (decode_text(&bytes), None),
        other => return Err(ImportError::Unsupported(other.to_string())),
    };
    let text = normalize_whitespace(&text);
    if text.is_empty() {
        return Err(ImportError::Empty);
    }
    Ok(Imported { text, original_docx })
}

/// UTF-8 when valid, latin-1 otherwise — mirrors the Mac importer's fallback.
fn decode_text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

fn extract_pdf(bytes: &[u8]) -> Result<String, ImportError> {
    // pdf-extract panics on some malformed documents rather than returning an
    // error, so treat a panic as "unreadable" instead of taking the app down
    // mid-interview.
    let parsed = std::panic::catch_unwind(|| pdf_extract::extract_text_from_mem(bytes));
    match parsed {
        Ok(Ok(text)) => Ok(text),
        Ok(Err(e)) => Err(ImportError::Unreadable(e.to_string())),
        Err(_) => Err(ImportError::Unreadable("malformed PDF".into())),
    }
}

/// A DOCX is a ZIP holding `word/document.xml`. Pull the text out of `<w:t>`
/// runs, treating `<w:p>` as a paragraph break and `<w:tab>` / `<w:br>` as
/// tab / newline — the same rules as the Mac XML parser delegate.
fn extract_docx(bytes: &[u8]) -> Result<String, ImportError> {
    let reader = std::io::Cursor::new(bytes);
    let mut zip = zip::ZipArchive::new(reader).map_err(|e| ImportError::Unreadable(e.to_string()))?;
    let mut xml = String::new();
    {
        use std::io::Read;
        let mut entry = zip
            .by_name("word/document.xml")
            .map_err(|_| ImportError::Unreadable("not a Word document".into()))?;
        entry.read_to_string(&mut xml).map_err(|e| ImportError::Unreadable(e.to_string()))?;
    }
    Ok(docx_xml_to_text(&xml))
}

/// Minimal WordprocessingML text scan. Deliberately not a full XML parser: we
/// only need character data inside `<w:t>` plus a few break elements.
fn docx_xml_to_text(xml: &str) -> String {
    let mut out = String::new();
    let mut para = String::new();
    let mut rest = xml;
    let mut in_text = false;

    while let Some(lt) = rest.find('<') {
        // Character data before this tag.
        if in_text {
            para.push_str(&unescape_xml(&rest[..lt]));
        }
        rest = &rest[lt + 1..];
        let Some(gt) = rest.find('>') else { break };
        let tag = &rest[..gt];
        rest = &rest[gt + 1..];

        let name_end = tag.find(|c: char| c.is_whitespace() || c == '/').unwrap_or(tag.len());
        let name = &tag[..name_end];
        match name {
            "w:t" => in_text = !tag.starts_with('/') && !tag.ends_with('/'),
            "/w:t" => in_text = false,
            "w:tab" => para.push('\t'),
            "w:br" | "w:cr" => para.push('\n'),
            "/w:p" => {
                out.push_str(&para);
                out.push('\n');
                para.clear();
            }
            _ => {}
        }
    }
    out.push_str(&para);
    out
}

fn unescape_xml(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

/// Strip RTF control words, keeping the literal text. Handles `\par`/`\line`
/// as newlines, `\'hh` hex escapes, `\\`/`\{`/`\}` literals, and skips the
/// binary-ish destination groups (fonts, colors, stylesheet, pictures).
fn extract_rtf(rtf: &str) -> String {
    let bytes: Vec<char> = rtf.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut depth = 0i32;
    // Group depth at which we started skipping a destination, if any.
    let mut skip_until: Option<i32> = None;

    while i < bytes.len() {
        let c = bytes[i];
        match c {
            '{' => {
                depth += 1;
                i += 1;
            }
            '}' => {
                if let Some(d) = skip_until {
                    if depth <= d {
                        skip_until = None;
                    }
                }
                depth -= 1;
                i += 1;
            }
            '\\' => {
                i += 1;
                if i >= bytes.len() {
                    break;
                }
                let next = bytes[i];
                if next == '\\' || next == '{' || next == '}' {
                    if skip_until.is_none() {
                        out.push(next);
                    }
                    i += 1;
                    continue;
                }
                if next == '\'' {
                    // \'hh — a raw byte in the current codepage.
                    let hex: String = bytes.iter().skip(i + 1).take(2).collect();
                    if let Ok(b) = u8::from_str_radix(&hex, 16) {
                        if skip_until.is_none() {
                            out.push(b as char);
                        }
                    }
                    i += 3;
                    continue;
                }
                // A control word: letters, optional numeric parameter.
                let start = i;
                while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
                    i += 1;
                }
                let word: String = bytes[start..i].iter().collect();
                if i < bytes.len() && (bytes[i] == '-' || bytes[i].is_ascii_digit()) {
                    if bytes[i] == '-' {
                        i += 1;
                    }
                    while i < bytes.len() && bytes[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                // A single trailing space is the delimiter, not content.
                if i < bytes.len() && bytes[i] == ' ' {
                    i += 1;
                }
                match word.as_str() {
                    "par" | "line" | "pard" if skip_until.is_none() => out.push('\n'),
                    "tab" if skip_until.is_none() => out.push('\t'),
                    // Destinations whose contents are metadata, not body text.
                    "fonttbl" | "colortbl" | "stylesheet" | "info" | "pict" | "object"
                    | "themedata" | "colorschememapping" | "datastore" | "generator"
                        if skip_until.is_none() =>
                    {
                        skip_until = Some(depth)
                    }
                    _ => {}
                }
            }
            '\r' | '\n' => i += 1, // raw line breaks in RTF are not content
            _ => {
                if skip_until.is_none() {
                    out.push(c);
                }
                i += 1;
            }
        }
    }
    out
}

/// Trim each line and collapse runs of blank lines to one.
pub fn normalize_whitespace(text: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let mut blanks = 0;
    for line in text.split('\n') {
        let line = line.trim();
        if line.is_empty() {
            blanks += 1;
            if blanks <= 1 {
                out.push("");
            }
        } else {
            blanks = 0;
            out.push(line);
        }
    }
    out.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docx_paragraphs_become_lines() {
        let xml = r#"<w:document><w:body>
            <w:p><w:r><w:t>Alex Carter</w:t></w:r></w:p>
            <w:p><w:r><w:t>Senior</w:t></w:r><w:r><w:t xml:space="preserve"> Engineer</w:t></w:r></w:p>
            <w:p><w:r><w:t>A</w:t></w:r><w:tab/><w:r><w:t>B</w:t></w:r></w:p>
        </w:body></w:document>"#;
        let text = normalize_whitespace(&docx_xml_to_text(xml));
        assert_eq!(text, "Alex Carter\nSenior Engineer\nA\tB");
    }

    #[test]
    fn docx_unescapes_entities() {
        let xml = "<w:p><w:r><w:t>R&amp;D &lt;lead&gt;</w:t></w:r></w:p>";
        assert_eq!(docx_xml_to_text(xml).trim(), "R&D <lead>");
    }

    #[test]
    fn docx_ignores_markup_outside_text_runs() {
        // Attribute values and element names must never leak into the output.
        let xml = r#"<w:p w14:paraId="12AB"><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
                     <w:r><w:rPr><w:b/></w:rPr><w:t>Experience</w:t></w:r></w:p>"#;
        assert_eq!(docx_xml_to_text(xml).trim(), "Experience");
    }

    #[test]
    fn rtf_keeps_text_drops_control_words() {
        let rtf = r"{\rtf1\ansi\deff0{\fonttbl{\f0\fnil Helvetica;}}
\f0\fs24 Alex Carter\par Senior Engineer\par}";
        let text = normalize_whitespace(&extract_rtf(rtf));
        assert_eq!(text, "Alex Carter\nSenior Engineer");
    }

    #[test]
    fn rtf_decodes_hex_escapes_and_literal_braces() {
        let rtf = r"{\rtf1 caf\'e9 \{braced\}}";
        assert_eq!(normalize_whitespace(&extract_rtf(rtf)), "café {braced}");
    }

    #[test]
    fn normalize_collapses_blank_runs() {
        let messy = "  Title  \n\n\n\n  body  \n\n\n";
        assert_eq!(normalize_whitespace(messy), "Title\n\nbody");
    }

    #[test]
    fn suggested_name_cleans_separators() {
        let p = Path::new("/tmp/Alex_Carter-resume.docx");
        assert_eq!(suggested_name(p), "Alex Carter resume");
    }

    #[test]
    fn unsupported_extension_is_reported() {
        let dir = std::env::temp_dir().join(format!("tc-import-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("notes.pages");
        std::fs::write(&p, b"x").unwrap();
        assert!(!is_supported(&p));
        match import(&p) {
            Err(ImportError::Unsupported(ext)) => assert_eq!(ext, "pages"),
            other => panic!("expected Unsupported, got {other:?}", other = other.map(|_| ())),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn plain_text_round_trips() {
        let dir = std::env::temp_dir().join(format!("tc-import-txt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("resume.md");
        std::fs::write(&p, b"# Alex\n\n\n- Rust\n").unwrap();
        let out = import(&p).unwrap();
        assert_eq!(out.text, "# Alex\n\n- Rust");
        assert!(out.original_docx.is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
