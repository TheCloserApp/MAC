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
