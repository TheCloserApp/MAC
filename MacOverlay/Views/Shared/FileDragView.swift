import SwiftUI
import AppKit

struct FileDragView: NSViewRepresentable {
    let fileURL: URL
    func makeNSView(context: Context) -> FileDragNSView { FileDragNSView() }
    func updateNSView(_ nsView: FileDragNSView, context: Context) { nsView.fileURL = fileURL }
}

final class FileDragNSView: NSView, NSDraggingSource {
    var fileURL: URL?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: 40, height: 40), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}
