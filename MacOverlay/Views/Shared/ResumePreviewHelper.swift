import AppKit
import QuickLookUI

final class ResumePreviewHelper: NSObject, QLPreviewPanelDataSource {
    static let shared = ResumePreviewHelper()
    private var previewURL: URL?

    func show(url: URL) {
        previewURL = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Preview a DOCX blob held in memory (e.g. a saved ResumePreset's
    /// `originalDOCX`). Writes the bytes to a temp file with the given
    /// `suggestedFilename` so QuickLook picks the right preview, then
    /// hands off to `show(url:)`. Returns the temp URL so the caller can
    /// hold onto it if they want — it's safe to discard since QuickLook
    /// only reads it when the panel is open.
    @discardableResult
    func showDOCX(_ data: Data, suggestedFilename: String = "preview.docx") -> URL? {
        let safeName = suggestedFilename.isEmpty
            ? "preview.docx"
            : suggestedFilename
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-preview-\(UUID().uuidString)-\(safeName)")
        do {
            try data.write(to: url, options: .atomic)
            show(url: url)
            return url
        } catch {
            return nil
        }
    }

    /// Fallback preview for resumes imported from PDF/RTF/TXT (no original
    /// DOCX retained). Renders the text into a tiny dark HTML document so
    /// QuickLook keeps the same ChatGPT-style shade as the overlay.
    @discardableResult
    func showPlainText(_ text: String, suggestedName: String = "resume") -> URL? {
        let safe = suggestedName.isEmpty ? "resume" : suggestedName
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-preview-\(UUID().uuidString)-\(safe).html")
        do {
            try themedPlainTextHTML(text, title: safe).write(to: url, atomically: true, encoding: .utf8)
            show(url: url)
            return url
        } catch {
            return nil
        }
    }

    private func themedPlainTextHTML(_ text: String, title: String) -> String {
        let escapedTitle = escapeHTML(title)
        let escapedText = escapeHTML(text)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>
        :root { color-scheme: dark; }
        body {
            margin: 0;
            background: #212121;
            color: #ececec;
            font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        main {
            max-width: 860px;
            margin: 0 auto;
            padding: 32px;
        }
        h1 {
            margin: 0 0 18px;
            color: #ececec;
            font-size: 18px;
            font-weight: 650;
        }
        pre {
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            margin: 0;
            padding: 20px;
            background: #272727;
            border: 1px solid rgba(255,255,255,.10);
            border-radius: 12px;
            color: #ececec;
            line-height: 1.45;
            font: 13px "SF Mono", Menlo, monospace;
        }
        </style>
        </head>
        <body><main><h1>\(escapedTitle)</h1><pre>\(escapedText)</pre></main></body>
        </html>
        """
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

extension Notification.Name {
    static let captureScreenshot = Notification.Name("captureScreenshot")
}
