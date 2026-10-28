import SwiftUI
import AppKit

/// Plain `key: value` editor for environment variables, with live syntax coloring:
/// keys in blue, values in the environment's scope color, `//` rows dimmed. Rows are
/// parsed back into the model on a short debounce so the form and text views stay in sync.
struct PlainVariableEditor: NSViewRepresentable {
    @Binding var rows: [KeyValue]
    var scopeColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = FocusableTextView(usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = VariableTextCodec.text(from: rows)
        textView.delegate = context.coordinator
        scroll.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.lastPushedText = textView.string
        context.coordinator.highlight()
        DispatchQueue.main.async {
            guard let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // While the user is typing, the model echo must not overwrite the buffer: the
        // codec normalises text (`key` becomes `key: `) on every parse and rewriting it
        // mid-edit used to drop the caret and swallow input.
        if let window = textView.window, window.firstResponder === textView {
            return
        }
        let text = VariableTextCodec.text(from: rows)
        if text != context.coordinator.lastPushedText, textView.string != text {
            context.coordinator.lastPushedText = text
            textView.string = text
            context.coordinator.highlight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainVariableEditor
        weak var textView: NSTextView?
        var lastPushedText = ""
        private var parseTask: Task<Void, Never>?
        private var highlightTask: Task<Void, Never>?

        init(_ parent: PlainVariableEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            lastPushedText = textView.string
            scheduleHighlight()
            parseTask?.cancel()
            let text = textView.string
            parseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                let parsed = VariableTextCodec.rows(from: text)
                // Keep existing row identities so the form view does not rebuild every
                // 200ms while the text is being edited.
                var merged: [KeyValue] = []
                merged.reserveCapacity(parsed.count)
                for (index, row) in parsed.enumerated() {
                    var copy = row
                    if self.parent.rows.indices.contains(index) {
                        copy.id = self.parent.rows[index].id
                    }
                    merged.append(copy)
                }
                if merged != self.parent.rows {
                    self.parent.rows = merged
                }
            }
        }

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                self?.highlight()
            }
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            if textView.hasMarkedText() { return }

            let text = storage.string as NSString
            let fullRange = NSRange(location: 0, length: text.length)
            let selection = textView.selectedRange()
            let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            let base: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ]

            storage.beginEditing()
            storage.setAttributes(base, range: fullRange)

            var index = 0
            while index < text.length {
                let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
                var contentLength = lineRange.length
                while contentLength > 0 {
                    let last = text.character(at: lineRange.location + contentLength - 1)
                    if last == 0x0A || last == 0x0D { contentLength -= 1 } else { break }
                }
                let content = NSRange(location: lineRange.location, length: contentLength)
                colorLine(content, in: text, storage: storage, keyFont: keyFont)
                index = lineRange.location + max(lineRange.length, 1)
            }

            storage.endEditing()
            textView.typingAttributes = base
            if selection.location <= text.length {
                textView.setSelectedRange(selection)
            }
        }

        private func colorLine(_ range: NSRange, in text: NSString, storage: NSTextStorage, keyFont: NSFont) {
            guard range.length > 0 else { return }
            let line = text.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return }

            if trimmed.hasPrefix("//") {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
                return
            }

            guard let separatorIndex = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                storage.addAttributes(
                    [.foregroundColor: NSColor.systemBlue, .font: keyFont],
                    range: range
                )
                return
            }
            let keyLength = (line[..<separatorIndex] as Substring).utf16.count
            let keyRange = NSRange(location: range.location, length: keyLength)
            if keyRange.length > 0 {
                storage.addAttributes(
                    [.foregroundColor: NSColor.systemBlue, .font: keyFont],
                    range: keyRange
                )
            }
            let separatorRange = NSRange(location: range.location + keyLength, length: 1)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: separatorRange)
            let valueStart = range.location + keyLength + 1
            let valueLength = range.length - keyLength - 1
            if valueLength > 0 {
                storage.addAttribute(
                    .foregroundColor,
                    value: parent.scopeColor,
                    range: NSRange(location: valueStart, length: valueLength)
                )
            }
        }
    }
}

/// Text view that always wins the click: it accepts the first mouse (even when the window
/// is inactive) and explicitly takes first responder on mouse down. Without this the
/// borderless window occasionally left clicks focused on the hosting view.
private final class FocusableTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKey()
            }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
        super.mouseDown(with: event)
    }
}
