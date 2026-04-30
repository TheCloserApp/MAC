import SwiftUI
import AppKit

/// A drop-down chip with a custom label and a trailing chevron, backed by
/// `NSMenu.popUp(...)` instead of SwiftUI's `Menu`. SwiftUI's Menu on macOS
/// renders a system disclosure indicator on the leading edge of the label
/// in some configurations even when the indicator is hidden — using NSMenu
/// directly gives us full control over chevron placement.
struct PopUpItem {
    let title: String
    let isSelected: Bool
    let isSection: Bool
    let action: (() -> Void)?

    static func option(_ title: String,
                       isSelected: Bool = false,
                       action: @escaping () -> Void) -> PopUpItem {
        PopUpItem(title: title, isSelected: isSelected, isSection: false, action: action)
    }

    static func section(_ title: String) -> PopUpItem {
        PopUpItem(title: title, isSelected: false, isSection: true, action: nil)
    }
}

struct PopUpChip<Label: View>: View {
    let items: () -> [PopUpItem]
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            showMenu()
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private func showMenu() {
        let menu = NSMenu()
        let target = MenuTarget()
        for it in items() {
            if it.isSection {
                let header = NSMenuItem()
                header.title = it.title
                header.isEnabled = false
                menu.addItem(header)
            } else {
                let mi = NSMenuItem(
                    title: it.title,
                    action: #selector(MenuTarget.fire(_:)),
                    keyEquivalent: ""
                )
                mi.target = target
                mi.state = it.isSelected ? .on : .off
                mi.representedObject = it.action
                menu.addItem(mi)
            }
        }
        // Retain the target while the menu is up.
        objc_setAssociatedObject(menu, &MenuTarget.assoc, target, .OBJC_ASSOCIATION_RETAIN)

        // Pop up below the current event location.
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            let location = view.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: location, in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

private final class MenuTarget: NSObject {
    static var assoc: UInt8 = 0
    @objc func fire(_ sender: NSMenuItem) {
        if let block = sender.representedObject as? () -> Void {
            block()
        }
    }
}

