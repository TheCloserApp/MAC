import SwiftUI

/// Lightweight markdown renderer. Parses once per `text` and caches the block
/// list so re-renders (opacity transitions, parent body invalidations) don't
/// re-tokenise long responses.
struct MarkdownResponseView: View {
    let text: String

    enum Block {
        case code(lang: String, body: String)
        case heading(level: Int, text: String)
        case bullet(String)
        case plain(String)
    }

    var body: some View {
        let blocks = MarkdownParseCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 5) {
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
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .textSelection(.enabled)
                }
            }
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))

        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? 14 : level == 2 ? 13 : 12, weight: .semibold))

        case .bullet(let text):
            HStack(alignment: .top, spacing: 5) {
                Text("•")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 10, alignment: .center)
                inlineText(text)
                    .font(.system(size: 12))
            }

        case .plain(let text):
            inlineText(text)
                .font(.system(size: 12))
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
    private var blockCache: [String: [MarkdownResponseView.Block]] = [:]
    private var attrCache:  [String: AttributedString?] = [:]
    private let maxEntries = 64

    func blocks(for text: String) -> [MarkdownResponseView.Block] {
        blockQueue.sync {
            if let hit = blockCache[text] { return hit }
            let parsed = Self.parse(text)
            if blockCache.count >= maxEntries { blockCache.removeAll(keepingCapacity: true) }
            blockCache[text] = parsed
            return parsed
        }
    }

    func attributed(for string: String) -> AttributedString? {
        attrQueue.sync {
            if let hit = attrCache[string] { return hit }
            let parsed = try? AttributedString(markdown: string)
            if attrCache.count >= maxEntries { attrCache.removeAll(keepingCapacity: true) }
            attrCache[string] = parsed
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
