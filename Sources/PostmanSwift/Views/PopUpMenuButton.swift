import SwiftUI
import AppKit

/// Small AppKit-backed icon button that pops up a native NSMenu. SwiftUI's `Menu`
/// flattens its label into a template and overrides the color, so a menu that has to
/// match the sidebar's gray chevrons needs to draw the icon itself.
struct PopUpMenuButton: NSViewRepresentable {
    struct Item {
        let title: String
        let isSeparator: Bool
        let action: () -> Void

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.isSeparator = false
            self.action = action
        }

        private init(separator: Bool) {
            self.title = ""
            self.isSeparator = separator
            self.action = {}
        }

        static var separator: Item { Item(separator: true) }
    }

    var systemImage: String
    var help: String = ""
    var iconColor: NSColor = .tertiaryLabelColor
    var items: [Item]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HoverMenuButton {
        let button = HoverMenuButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.image = symbolImage
        button.contentTintColor = iconColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = help
        context.coordinator.items = items
        return button
    }

    func updateNSView(_ button: HoverMenuButton, context: Context) {
        context.coordinator.items = items
        button.image = symbolImage
        button.contentTintColor = iconColor
        button.toolTip = help
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HoverMenuButton, context: Context) -> CGSize? {
        CGSize(width: 24, height: 22)
    }

    private var symbolImage: NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    final class Coordinator: NSObject {
        var items: [Item] = []

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            for (index, item) in items.enumerated() {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let entry = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                menu.addItem(entry)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        }

        @objc func fire(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].action()
        }
    }
}

final class HoverMenuButton: NSButton {
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
