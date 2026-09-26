import AppKit
import SwiftUI

/// The "On a call in Zoom?" prompt, in the top-right corner just below the
/// menu bar. A borderless panel of our own rather than a system
/// notification: like every window of this app it's excluded from screen
/// capture, and a notification would show up in the call's screen share.
@MainActor
final class CallPromptPanel {
    private var panel: NSPanel?

    func show(appName: String, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let host = NSHostingView(rootView: CallPromptCard(appName: appName, onStart: onStart, onDismiss: onDismiss))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.sharingType = NSWindow.screenShareInvisible ? .none : .readOnly

        // The card's own padding keeps it 12pt off the screen edge and the
        // menu bar, so the panel itself sits flush in the corner.
        if let screen = NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width,
                                         y: frame.maxY - panel.frame.height))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered,
                            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        return panel
    }
}

struct CallPromptCard: View {
    let appName: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WaveformLogo()
                    .frame(width: 16, height: 16)
                Text("On a call in \(appName)?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Design.Ink.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Not now")
            }
            Text("Start your interview and TheCloser will listen and answer.")
                .font(.system(size: 11))
                .foregroundColor(Design.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onStart) {
                    Text("Start interview")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Design.Ink.inverse)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Design.Ink.primary))
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Text("Not now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Design.Surface.shellFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Design.Surface.hairline, lineWidth: 0.75))
        .padding(12)   // room for the shadow inside the borderless panel
        .designShadow(Design.Shadow.raised)
        .preferredColorScheme(.dark)
    }
}
