import SwiftUI
import AppKit

/// Lightweight markdown renderer. Parses once per `text` and caches the block
/// list so re-renders (opacity transitions, parent body invalidations) don't
/// re-tokenise long responses.
struct MarkdownResponseView: View {
    let text: String
    /// Base body-text size. Headings/bullets/code derive from it, so the
    /// live-interview Focus view can render answers slightly larger for
    /// read-while-speaking without touching every call site.
    var baseSize: CGFloat = 12

    enum Block {
        case code(lang: String, body: String)
        case heading(level: Int, text: String)
        case bullet(String)
        case plain(String)
    }

    var body: some View {
        let blocks = MarkdownParseCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 5) {
            // Identity by `\.offset` is intentional: the dominant case is
            // streaming output where the last block grows token-by-token.
            // Offset keeps the trailing block's view stable across renders
            // (preserving inner @State like text selection and code-block
            // copy feedback). Content-based identity would rebuild that
            // view on every token. The rare mid-stream insertion case
            // causes a minor visual glitch and is acceptable.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .code(let lang, let body):
            CodeBlockView(language: lang, code: body)

        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? baseSize + 2 : level == 2 ? baseSize + 1 : baseSize,
                              weight: .semibold))

        case .bullet(let text):
            HStack(alignment: .top, spacing: 5) {
                Text("•")
                    .font(.system(size: baseSize))
                    .foregroundColor(.secondary)
                    .frame(width: 10, alignment: .center)
                inlineText(text)
                    .font(.system(size: baseSize))
            }

        case .plain(let text):
            inlineText(text)
                .font(.system(size: baseSize))
        }
    }

    @ViewBuilder
    private func inlineText(_ string: String) -> some View {
        if let attr = MarkdownParseCache.shared.attributed(for: string) {
            Text(attr).textSelection(.enabled)
        } else {
            Text(string).textSelection(.enabled)
        }
    }
}

/// Process-wide cache. Parsing short responses is cheap but streaming responses
/// invalidate the view constantly and previously re-parsed from scratch on
/// every keystroke-sized delta.
final class MarkdownParseCache {
    static let shared = MarkdownParseCache()

    private let blockQueue = DispatchQueue(label: "md.block.cache")
    private let attrQueue  = DispatchQueue(label: "md.attr.cache")
    /// Insertion-ordered LRU. Earliest entries are at the start of `keys`.
    private var blockCache: [String: [MarkdownResponseView.Block]] = [:]
    private var blockOrder: [String] = []
    private var attrCache:  [String: AttributedString?] = [:]
    private var attrOrder:  [String] = []
    private let maxEntries = 128

    func blocks(for text: String) -> [MarkdownResponseView.Block] {
        blockQueue.sync {
            if let hit = blockCache[text] { return hit }
            let parsed = Self.parse(text)
            blockCache[text] = parsed
            blockOrder.append(text)
            // Drop the oldest 25% in one batch so we amortise the eviction
            // cost rather than rehashing the dictionary on every miss past
            // the threshold.
            if blockOrder.count > maxEntries {
                let drop = maxEntries / 4
                for k in blockOrder.prefix(drop) { blockCache.removeValue(forKey: k) }
                blockOrder.removeFirst(drop)
            }
            return parsed
        }
    }

    func attributed(for string: String) -> AttributedString? {
        attrQueue.sync {
            if let hit = attrCache[string] { return hit }
            let parsed = try? AttributedString(markdown: string)
            attrCache[string] = parsed
            attrOrder.append(string)
            if attrOrder.count > maxEntries {
                let drop = maxEntries / 4
                for k in attrOrder.prefix(drop) { attrCache.removeValue(forKey: k) }
                attrOrder.removeFirst(drop)
            }
            return parsed
        }
    }

    private static func parse(_ text: String) -> [MarkdownResponseView.Block] {
        var result: [MarkdownResponseView.Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuf: [String] = []

        func flush() {
            let joined = textBuf.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.plain(joined)) }
            textBuf = []
        }

        while i < lines.count {
            let raw  = lines[i]
            let trim = raw.trimmingCharacters(in: .whitespaces)

            if trim.hasPrefix("```") {
                flush()
                let lang = String(trim.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(lines[i])
                    i += 1
                }
                result.append(.code(lang: lang, body: code.joined(separator: "\n")))
            } else if trim.hasPrefix("### ") {
                flush(); result.append(.heading(level: 3, text: String(trim.dropFirst(4))))
            } else if trim.hasPrefix("## ") {
                flush(); result.append(.heading(level: 2, text: String(trim.dropFirst(3))))
            } else if trim.hasPrefix("# ") {
                flush(); result.append(.heading(level: 1, text: String(trim.dropFirst(2))))
            } else if trim.hasPrefix("- ") || trim.hasPrefix("* ") || trim.hasPrefix("+ ") {
                flush(); result.append(.bullet(String(trim.dropFirst(2))))
            } else if let r = trim.range(of: #"^\d+\. "#, options: .regularExpression) {
                flush(); result.append(.bullet(String(trim[r.upperBound...])))
            } else if trim.isEmpty {
                flush()
            } else {
                textBuf.append(raw)
            }
            i += 1
        }
        flush()
        return result
    }
}

// MARK: - Code block

/// Code block rendered as its own view so we can host a header bar
/// (language label + copy button) without bloating the renderer's
/// switch statement, and so each block can keep its own "copied"
/// transient state. Long lines wrap by default — the previous
/// horizontal-scroll-only layout cut off most snippets in the narrow
/// chat pane and made them look unformatted.
private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    /// Pending "Copied → Copy" reset task. Stored so a second copy within
    /// the dwell cancels the previous reset, otherwise the in-flight reset
    /// fires while the second copy is still showing its confirmation.
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
            codeBody
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(language.isEmpty ? "code" : language.lowercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            Spacer()
            Button(action: copy) {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// The actual code text. We use `.fixedSize(horizontal: false,
    /// vertical: true)` so SwiftUI is allowed to grow vertically to fit
    /// wrapped lines instead of clipping at the available width. Each
    /// line is monospaced; tabs get rendered as four spaces because
    /// SwiftUI's default tab handling collapses leading whitespace and
    /// makes indented blocks look flush-left.
    private var codeBody: some View {
        Text(normalize(code))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary.opacity(0.95))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    private func normalize(_ s: String) -> String {
        // Convert tabs to four spaces so indentation actually shows.
        // Strip the trailing newline some models emit at the end of a
        // fenced block — it adds an empty visual row.
        let detabbed = s.replacingOccurrences(of: "\t", with: "    ")
        return detabbed.hasSuffix("\n") ? String(detabbed.dropLast()) : detabbed
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeOut(duration: 0.18)) { copied = true }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { copied = false }
        }
    }
}
