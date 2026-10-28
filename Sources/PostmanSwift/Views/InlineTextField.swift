import SwiftUI
import AppKit

/// NSTextField-backed input used where SwiftUI's TextField would not take focus reliably:
/// the search field and the environment variable rows. The field accepts the first mouse
/// click even while the window is inactive, so one click both activates the window and
/// places the caret; it also keeps marked text (IME) intact by only pushing the binding
/// into the editor when the model changed elsewhere.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 12
    var monospaced = false
    var textColor: NSColor = .labelColor
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstMouseTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        context.coordinator.field = field
        context.coordinator.lastPushedText = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if text != context.coordinator.lastPushedText {
            context.coordinator.lastPushedText = text
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        } else if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
    }

    private var font: NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        weak var field: NSTextField?
        var lastPushedText: String?

        init(_ parent: InlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            lastPushedText = field.stringValue
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

final class FirstMouseTextField: NSTextField {
    /// Called while moving over `{{...}}` tokens (nil when leaving a token).
    var onHoverToken: ((VariableToken?, NSRect) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, !window.isKeyWindow {
            window.makeKey()
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let onHoverToken, !stringValue.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let font = self.font ?? .systemFont(ofSize: 12)
        if let hit = VariableTokenScanner.hit(atX: point.x, text: stringValue, font: font) {
            onHoverToken(hit.token, hit.rect)
        } else {
            onHoverToken(nil, .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverToken?(nil, .zero)
    }
}
