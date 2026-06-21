import Foundation

enum NoteSource: String, Codable { case ai, manual }

struct NoteEntry: Identifiable, Codable {
    var id        = UUID()
    let timestamp: Date
    let source:    NoteSource
    let content:   String
    let mode:      SessionMode
}

class NotesManager {
    static let shared = NotesManager()
    private(set) var entries: [NoteEntry] = []

    func add(content: String, source: NoteSource, mode: SessionMode) {
        entries.append(NoteEntry(timestamp: Date(), source: source, content: content, mode: mode))
    }

    func clear() { entries = [] }

    func exportAsMarkdown() throws -> URL {
        var md = "# thecloser Session Notes\n_Exported \(Date().formatted())_\n\n"
        for e in entries {
            let icon = e.source == .ai ? "🤖" : "✏️"
            md += "### \(icon) \(e.mode.displayName) · \(e.timestamp.formatted(date: .omitted, time: .shortened))\n\n\(e.content)\n\n---\n\n"
        }
        return try write(content: md, ext: "md")
    }

    func exportAsPlainText() throws -> URL {
        var txt = "thecloser Session Notes — \(Date().formatted())\n\n"
        for e in entries {
            txt += "[\(e.mode.displayName)] [\(e.source.rawValue.uppercased())] \(e.timestamp.formatted(date: .omitted, time: .shortened))\n\(e.content)\n\n"
        }
        return try write(content: txt, ext: "txt")
    }

    private func write(content: String, ext: String) throws -> URL {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "thecloser-Notes-\(formatter.string(from: Date())).\(ext)"
        let url  = downloads.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
