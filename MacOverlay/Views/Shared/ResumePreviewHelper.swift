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
    /// DOCX retained). Drops the plain-text content into a temp .txt file
    /// so QuickLook still has something to render.
    @discardableResult
    func showPlainText(_ text: String, suggestedName: String = "resume") -> URL? {
        let safe = suggestedName.isEmpty ? "resume" : suggestedName
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-preview-\(UUID().uuidString)-\(safe).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            show(url: url)
            return url
        } catch {
            return nil
        }
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
