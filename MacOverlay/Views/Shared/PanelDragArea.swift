import SwiftUI
import AppKit

/// Drag-to-move for the overlay panel.
///
/// The panel sets `isMovableByWindowBackground`, but AppKit's background
/// drag only fires where nothing else claims the mouse-down — and the shell
/// is wall-to-wall filled capsules, cards, and controls, so in practice
/// almost none of the overlay could actually be grabbed.
///
/// Two ways in:
/// - `PanelDragArea` — an invisible layer to put BEHIND chrome. Buttons and
///   text fields sit in front and keep their own clicks; the gaps between
///   them drag the window.
/// - `.panelDraggable(didDrag:)` — for chrome that IS a control, where
///   there is no gap to grab (the brand pill in `.pill` stage is a 44×44
///   button that covers essentially the whole collapsed overlay). The
///   gesture runs alongside the control's own, and `didDrag` tells the
///   control to skip its click when the press turned out to be a drag.
struct PanelDragArea: View {
    @State private var didDrag = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .panelDraggable(didDrag: $didDrag)
    }
}

/// Reports cumulative screen-space offsets to `vm.onPanelDrag`, which
/// AppDelegate applies to the panel's origin.
private struct PanelDragGesture: ViewModifier {
    @Environment(OverlayViewModel.self) private var vm
    @Binding var didDrag: Bool

    /// Absolute screen point where this drag began.
    @State private var anchor: NSPoint?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            // A minimum distance means a plain click is still a click: the
            // gesture only engages once the pointer actually travels.
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    // Screen-space deltas, NOT SwiftUI's translation. The
                    // handle travels with the window it's moving, so a
                    // window-relative translation is measured against an
                    // origin that just shifted underneath it — each event
                    // then reports a delta polluted by the move it caused.
                    // Same feedback loop the corner resize grip avoids, and
                    // the same fix: `NSEvent.mouseLocation` is absolute and
                    // cannot feed back.
                    let loc = NSEvent.mouseLocation
                    if anchor == nil { anchor = loc }
                    guard let a = anchor else { return }
                    didDrag = true
                    vm.onPanelDrag?(loc.x - a.x, loc.y - a.y, false)
                }
                .onEnded { _ in
                    let loc = NSEvent.mouseLocation
                    let a = anchor ?? loc
                    vm.onPanelDrag?(loc.x - a.x, loc.y - a.y, true)
                    anchor = nil
                    // Clear on the next runloop turn, not now: the control's
                    // own click action fires in this same event and still
                    // needs to see that a drag happened. Clearing here — or
                    // leaving it to the control — would strand the flag true
                    // whenever a drag ends off the control, which happens
                    // every time the panel clamps at a screen edge and the
                    // cursor keeps going without it.
                    DispatchQueue.main.async { didDrag = false }
                }
        )
    }
}

extension View {
    /// Let this view drag the overlay panel while keeping its own gestures.
    ///
    /// `didDrag` flips true as soon as the press becomes a drag, and stays
    /// true until the control reads and clears it. A control that also has a
    /// click action must check it: the window follows the cursor, so the
    /// pointer is still inside the control on mouse-up and the click would
    /// otherwise fire at the end of every drag.
    func panelDraggable(didDrag: Binding<Bool>) -> some View {
        modifier(PanelDragGesture(didDrag: didDrag))
    }
}
