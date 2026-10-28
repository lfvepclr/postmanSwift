import SwiftUI
import AppKit
import WebKit
import PDFKit

// MARK: - Prepared display text

@MainActor
final class TextPreparationModel: ObservableObject {
    struct Prepared {
        let id: String
        let text: String
        let wraps: Bool
        let highlight: Bool
        let lines: Int
        let longLines: Bool
    }

    @Published private(set) var prepared: Prepared?
    @Published private(set) var isPreparing = false

    private var generation = UUID()
    private var task: Task<Void, Never>?

    func prepare(text: String, wrapRequested: Bool, maxDisplayBytes: Int?) {
        let key = Self.key(text: text, wraps: wrapRequested, maxDisplayBytes: maxDisplayBytes)
        if prepared?.id == key { return }

        let current = UUID()
        generation = current
        task?.cancel()

        if text.utf8.count <= 256_000 {
            prepared = Self.build(
                text: text,
                wrapRequested: wrapRequested,
                key: key,
                maxDisplayBytes: maxDisplayBytes
            )
            isPreparing = false
            return
        }

        isPreparing = true
        task = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(
                    text: text,
                    wrapRequested: wrapRequested,
                    key: key,
                    maxDisplayBytes: maxDisplayBytes
                )
            }.value
            guard !Task.isCancelled, generation == current else { return }
            prepared = built
            isPreparing = false
        }
    }

    nonisolated private static func key(text: String, wraps: Bool, maxDisplayBytes: Int?) -> String {
        "\(text.utf8.count)|\(text.prefix(24))|\(text.suffix(24))|\(wraps)|\(maxDisplayBytes ?? -1)"
    }

    nonisolated private static func build(
        text: String,
        wrapRequested: Bool,
        key: String,
        maxDisplayBytes: Int?
    ) -> Prepared {
        var source = text
        if let maxDisplayBytes, text.utf8.count > maxDisplayBytes {
            let megabytes = max(1, maxDisplayBytes / 1_048_576)
            let total = String(format: "%.1f", Double(text.utf8.count) / 1_048_576)
            source = String(decoding: text.utf8.prefix(maxDisplayBytes), as: UTF8.self)
                + "\n\n… 大文本仅显示前 \(megabytes) MB（共 \(total) MB）。完整内容请使用 Copy 或 Save。"
        }
        let longLine = DisplayText.hasVeryLongLine(source)
        let wraps = wrapRequested
        let display = wraps ? DisplayText.wrapVeryLongLines(source) : source
        let highlight = display.utf16.count <= 200_000 && !longLine
        var lines = 1
        for byte in display.utf8 where byte == 0x0A { lines += 1 }
        return Prepared(
            id: key,
            text: display,
            wraps: wraps,
            highlight: highlight,
            lines: lines,
            longLines: longLine
        )
    }
}

/// Read-only code view. Large payloads are prepared off the main thread and rendered with TextKit 2,
/// which lays out only the visible viewport instead of the whole document.
struct CodeTextView: View {
    var text: String
    var fontSize: CGFloat = 12
    var backgroundColor: NSColor = .clear
    var language: SyntaxLanguage = .plain
    /// Long single-line base64 blobs switch to horizontal scrolling automatically.
    var wrapVeryLongLines = false
    /// Bounds the text handed to TextKit. Preview still shows the full structure and the response
    /// header can Copy/Save the untouched body.
    var maxDisplayBytes: Int?

    @StateObject private var preparation = TextPreparationModel()

    private var preparationID: String {
        "\(text.utf8.count)|\(text.prefix(16))|\(text.suffix(16))|\(wrapVeryLongLines)|\(language.rawValue)|\(maxDisplayBytes ?? -1)"
    }

    var body: some View {
        ZStack {
            if let prepared = preparation.prepared {
                RawCodeTextView(
                    display: prepared.text,
                    wraps: prepared.wraps,
                    highlight: prepared.highlight,
                    lines: prepared.lines,
                    longLines: prepared.longLines,
                    language: language,
                    fontSize: fontSize,
                    backgroundColor: backgroundColor
                )
            }
            if preparation.isPreparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备大文本…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: preparationID) {
            preparation.prepare(text: text, wrapRequested: wrapVeryLongLines, maxDisplayBytes: maxDisplayBytes)
        }
    }
}

private struct RawCodeTextView: NSViewRepresentable {
    let display: String
    let wraps: Bool
    let highlight: Bool
    let lines: Int
    let longLines: Bool
    let language: SyntaxLanguage
    let fontSize: CGFloat
    let backgroundColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = backgroundColor != .clear
        textView.backgroundColor = backgroundColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = scrollView.contentView.bounds
        scrollView.documentView = textView

        context.coordinator.configure(textView, scrollView: scrollView, wraps: wraps)
        textView.string = display
        context.coordinator.resize(
            textView,
            scrollView: scrollView,
            wraps: wraps,
            lines: lines,
            longLines: longLines,
            fontSize: fontSize
        )
        context.coordinator.lastDisplay = display
        context.coordinator.lastWraps = wraps
        context.coordinator.applyHighlight(textView, enabled: highlight, language: language, fontSize: fontSize)
        context.coordinator.lastHighlight = highlight
        context.coordinator.lastLanguage = language
        context.coordinator.lastFontSize = fontSize
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.lastWraps != wraps {
            coordinator.configure(textView, scrollView: scrollView, wraps: wraps)
            coordinator.lastWraps = wraps
        }
        if coordinator.lastDisplay != display {
            textView.string = display
            coordinator.lastDisplay = display
            coordinator.lastHighlight = nil
            coordinator.invalidateResize()
        }
        coordinator.resize(
            textView,
            scrollView: scrollView,
            wraps: wraps,
            lines: lines,
            longLines: longLines,
            fontSize: fontSize
        )
        if coordinator.lastHighlight != highlight
            || coordinator.lastLanguage != language
            || coordinator.lastFontSize != fontSize {
            coordinator.applyHighlight(textView, enabled: highlight, language: language, fontSize: fontSize)
            coordinator.lastHighlight = highlight
            coordinator.lastLanguage = language
            coordinator.lastFontSize = fontSize
        }
    }

    final class Coordinator {
        var lastDisplay: String?
        var lastWraps: Bool?
        var lastHighlight: Bool?
        var lastLanguage: SyntaxLanguage?
        var lastFontSize: CGFloat?

        /// SwiftUI calls `updateNSView` for unrelated ancestors' changes. Re-running TextKit
        /// measurement and writing the same frame on every call made scrolling and typing stutter,
        /// so a resize only happens when an input that affects the document size changes.
        private struct ResizeState: Equatable {
            var displayLength: Int
            var wraps: Bool
            var lines: Int
            var longLines: Bool
            var fontSize: CGFloat
            var viewport: CGSize
        }

        private var lastResize: ResizeState?

        func invalidateResize() {
            lastResize = nil
        }

        func configure(_ textView: NSTextView, scrollView: NSScrollView, wraps: Bool) {
            assertTextKit2(textView)
            textView.minSize = NSSize(width: 0, height: 0)
            if wraps {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                scrollView.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = [.height]
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                scrollView.hasHorizontalScroller = true
            }
        }

        /// A TextKit 2 text view permanently falls back to TextKit 1 the moment `layoutManager`
        /// is touched. That fallback plus an estimated document height made large responses fill
        /// layout holes on the main thread for seconds. Fail loudly in debug builds instead.
        private func assertTextKit2(_ textView: NSTextView) {
            #if DEBUG
            assert(
                textView.textLayoutManager != nil,
                "TextKit 2 fell back to TextKit 1: avoid textView.layoutManager in read-only views"
            )
            #endif
        }

        /// TextKit 2 sizes the document lazily, so the document view stays one viewport tall. We
        /// estimate the height from the prepared line count instead of laying out the whole text.
        func resize(
            _ textView: NSTextView,
            scrollView: NSScrollView,
            wraps: Bool,
            lines: Int,
            longLines: Bool,
            fontSize: CGFloat
        ) {
            assertTextKit2(textView)
            let viewport = scrollView.contentSize
            guard viewport.width > 1, viewport.height > 1 else { return }

            let state = ResizeState(
                displayLength: textView.textStorage?.length ?? 0,
                wraps: wraps,
                lines: lines,
                longLines: longLines,
                fontSize: fontSize,
                viewport: viewport
            )
            guard state != lastResize else { return }
            let needsMeasure = lastResize.map {
                $0.displayLength != state.displayLength || $0.wraps != state.wraps || $0.fontSize != state.fontSize
            } ?? true
            lastResize = state

            if wraps {
                let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                let lineHeight = ceil(font.boundingRectForFont.height) + 1
                let insets = textView.textContainerInset
                // Soft breaks at 120 columns can still wrap again in a narrow pane. Overestimate
                // the document height so the end of a huge response is always reachable.
                let factor: CGFloat = longLines ? 2.3 : 1.4
                let height = max(
                    viewport.height,
                    CGFloat(max(1, lines)) * lineHeight * factor + insets.height * 2 + 4
                )
                applyFrame(NSRect(x: 0, y: 0, width: viewport.width, height: height), to: textView)
            } else {
                if needsMeasure {
                    textView.sizeToFit()
                }
                var frame = textView.frame
                frame.size.width = max(frame.width, viewport.width)
                frame.size.height = max(frame.height, viewport.height)
                applyFrame(frame, to: textView)
            }
        }

        private func applyFrame(_ frame: NSRect, to textView: NSTextView) {
            let current = textView.frame
            guard abs(current.width - frame.width) > 0.5
                || abs(current.height - frame.height) > 0.5
                || abs(current.origin.x - frame.origin.x) > 0.5
                || abs(current.origin.y - frame.origin.y) > 0.5
            else { return }
            textView.frame = frame
        }

        func applyHighlight(_ textView: NSTextView, enabled: Bool, language: SyntaxLanguage, fontSize: CGFloat) {
            if enabled {
                SyntaxHighlighter.apply(to: textView, language: language, fontSize: fontSize)
                return
            }
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.textColor = .labelColor
            guard let storage = textView.textStorage, storage.length <= 500_000 else { return }
            storage.setAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ],
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }
}

// MARK: - Editable code view

struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    var language: SyntaxLanguage = .javascript
    var variables: [VariableSuggestion] = []
    var scriptAPI: Bool = false
    /// Model updates are coalesced so a fast typist or a large paste does not rebuild the whole
    /// SwiftUI hierarchy on every keystroke.
    var commitDebounce: TimeInterval = 0.15
    /// Change this token to focus the editor (for example when a new mock case is selected).
    var focusToken: String?
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = HoverCodeTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(red: 1.0, green: 0.424, blue: 0.216, alpha: 1)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = scrollView.contentView.bounds
        scrollView.documentView = textView

        textView.string = text
        let coordinator = context.coordinator
        textView.onHoverToken = { [weak textView, weak coordinator] token, screenRect in
            guard let textView else { return }
            guard let token, let coordinator, let window = textView.window else {
                VariableTooltipController.shared.close()
                return
            }
            let lookup = VariableLookup(suggestions: coordinator.parent.variables)
            let windowRect = window.convertFromScreen(screenRect)
            let viewRect = textView.convert(windowRect, from: nil)
            VariableTooltipController.shared.show(lookup.info(for: token.name), relativeTo: viewRect, of: textView)
        }
        context.coordinator.configureEditingWrap(textView, scrollView: scrollView)
        context.coordinator.attach(textView)
        context.coordinator.lastCommittedLength = (text as NSString).length
        context.coordinator.lastFocusToken = focusToken
        if focusOnAppear, focusToken != nil {
            context.coordinator.focus(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        PerformanceProbe.measure("editorUpdate") {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let coordinator = context.coordinator
            coordinator.parent = self
            coordinator.attach(textView)

            if focusToken != coordinator.lastFocusToken {
                coordinator.lastFocusToken = focusToken
                if focusToken != nil {
                    coordinator.focus(textView)
                }
            }

            guard !coordinator.isEditing else { return }
            if textView.string != text {
                textView.string = text
                coordinator.lastCommittedLength = (text as NSString).length
                coordinator.configureEditingWrap(textView, scrollView: scrollView)
                coordinator.applyHighlightNow(textView)
            } else if coordinator.lastLanguage != language || coordinator.lastFontSize != fontSize {
                coordinator.applyHighlightNow(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        var isEditing = false
        var isHighlighting = false
        var lastLanguage: SyntaxLanguage?
        var lastFontSize: CGFloat?
        var lastCommittedLength = 0
        var lastFocusToken: String?

        private weak var textView: NSTextView?
        private var pendingText: String?
        private var commitWork: DispatchWorkItem?
        private var highlightWork: DispatchWorkItem?

        init(_ parent: CodeTextEditor) {
            self.parent = parent
        }

        func attach(_ textView: NSTextView) {
            self.textView = textView
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            flush()
            CompletionPopupController.shared.close()
        }

        func textDidChange(_ notification: Notification) {
            PerformanceProbe.event("editorKeystroke")
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            let newLength = (newText as NSString).length
            let delta = abs(newLength - lastCommittedLength)
            pendingText = newText
            scheduleCommit()

            if delta <= 4_096, !isLarge(textView) {
                scheduleHighlight(textView)
                showCompletions(textView)
            } else {
                CompletionPopupController.shared.close()
                if delta > 4_096, newLength <= 1_000_000,
                   let scrollView = textView.enclosingScrollView {
                    configureEditingWrap(textView, scrollView: scrollView)
                }
            }
        }

        private func isLarge(_ textView: NSTextView) -> Bool {
            (textView.string as NSString).length > 200_000
        }

        private func scheduleCommit() {
            commitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            commitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + parent.commitDebounce, execute: work)
        }

        func flush() {
            commitWork?.cancel()
            commitWork = nil
            guard let pendingText else { return }
            self.pendingText = nil
            lastCommittedLength = (pendingText as NSString).length
            parent.text = pendingText
            if lastCommittedLength <= 64_000, let textView, let scrollView = textView.enclosingScrollView {
                configureEditingWrap(textView, scrollView: scrollView)
            }
        }

        private func showCompletions(_ textView: NSTextView) {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret >= 0, caret <= ns.length, ns.length > 0 else {
                CompletionPopupController.shared.close()
                return
            }

            // Only the text immediately before the caret can open a completion. Copying the whole
            // multi-megabyte document here was the main source of paste/typing stalls.
            let windowLength = min(caret, 240)
            let windowStart = caret - windowLength
            let prefix = ns.substring(with: NSRange(location: windowStart, length: windowLength))
            let suffixLength = min(4, ns.length - caret)
            let suffix = suffixLength > 0 ? ns.substring(with: NSRange(location: caret, length: suffixLength)) : ""

            guard let detected = CompletionEngine.detect(
                text: prefix + suffix,
                caret: windowLength,
                variables: parent.variables,
                scriptAPI: parent.scriptAPI
            ) else {
                CompletionPopupController.shared.close()
                return
            }

            let range = NSRange(location: detected.range.location + windowStart, length: detected.range.length)
            let anchor = CompletionPopupController.screenRect(for: textView, at: caret)
            CompletionPopupController.shared.show(
                items: detected.items,
                anchor: anchor,
                editor: textView
            ) { [weak self, weak textView] item in
                guard let self, let textView else { return }
                textView.textStorage?.replaceCharacters(in: range, with: item.insertText)
                let caretAfter = range.location + (item.insertText as NSString).length
                textView.setSelectedRange(NSRange(location: caretAfter, length: 0))
                self.lastCommittedLength = (textView.string as NSString).length
                self.parent.text = textView.string
                self.applyHighlightNow(textView)
            }
        }

        func applyHighlightNow(_ textView: NSTextView) {
            PerformanceProbe.measure("editorHighlight") {
                applyHighlightBody(textView)
            }
        }

        private func applyHighlightBody(_ textView: NSTextView) {
            guard !isHighlighting else { return }
            lastLanguage = parent.language
            lastFontSize = parent.fontSize
            let length = (textView.string as NSString).length
            guard length <= 200_000, !DisplayText.hasVeryLongLine(textView.string) else {
                textView.font = .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
                textView.textColor = .labelColor
                return
            }
            isHighlighting = true
            SyntaxHighlighter.apply(to: textView, language: parent.language, fontSize: parent.fontSize)
            if !parent.variables.isEmpty,
               let storage = textView.textStorage,
               storage.length <= 200_000 {
                let known = Set(parent.variables.map(\.name)).union(DynamicVariableCatalog.supportedNames)
                SyntaxHighlighter.applyVariableColors(to: textView, known: known)
            }
            isHighlighting = false
        }

        private func scheduleHighlight(_ textView: NSTextView) {
            highlightWork?.cancel()
            guard !DisplayText.hasVeryLongLine(textView.string) else { return }
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlightNow(textView)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func configureEditingWrap(_ textView: NSTextView, scrollView: NSScrollView) {
            textView.minSize = NSSize(width: 0, height: 0)
            let viewport = scrollView.contentSize
            if viewport.width > 1 {
                textView.setFrameSize(NSSize(width: viewport.width, height: max(1, viewport.height)))
            }
            let longLine = DisplayText.hasVeryLongLine(textView.string)
            if longLine {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = [.height]
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                scrollView.hasHorizontalScroller = true
            } else {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                scrollView.hasHorizontalScroller = false
            }
            textView.allowsUndo = (textView.string as NSString).length <= 2_000_000
            resizeEditor(textView, scrollView: scrollView)
        }

        private func resizeEditor(_ textView: NSTextView, scrollView: NSScrollView) {
            let viewport = scrollView.contentSize
            guard viewport.width > 1 else { return }
            if DisplayText.hasVeryLongLine(textView.string) {
                textView.sizeToFit()
                var frame = textView.frame
                frame.size.height = max(frame.height, viewport.height)
                textView.frame = frame
                return
            }
            var lines = 1
            for byte in textView.string.utf8 where byte == 0x0A { lines += 1 }
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let lineHeight = ceil(font.boundingRectForFont.height) + 1
            let insets = textView.textContainerInset
            let height = max(
                viewport.height,
                CGFloat(lines) * lineHeight + insets.height * 2 + 4
            )
            textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: height)
        }

        func focus(_ textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, let window = textView.window else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
                self.isEditing = true
            }
        }

        func dismantle() {
            flush()
            CompletionPopupController.shared.close()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

enum DisplayText {
    static func hasVeryLongLine(_ text: String, minimumRun: Int = 2_048) -> Bool {
        var run = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                run = 0
            } else {
                run += 1
                if run >= minimumRun { return true }
            }
        }
        return false
    }

    /// Only rewrites text that actually contains a huge single line, and breaks on UTF-8 scalar
    /// boundaries so multi-byte characters stay intact. Always call this off the main thread.
    static func wrapVeryLongLines(_ text: String, column: Int = 120, minimumRun: Int = 2_048) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > minimumRun else { return text }
        guard hasVeryLongLine(text, minimumRun: minimumRun) else { return text }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / column + 16)
        var columnCount = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A {
                output.append(byte)
                columnCount = 0
                index += 1
                continue
            }
            output.append(byte)
            columnCount += 1
            index += 1
            if columnCount >= column,
               index < bytes.count,
               bytes[index] != 0x0A,
               bytes[index] & 0xC0 != 0x80 {
                output.append(0x0A)
                columnCount = 0
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

struct WebPreviewView: NSViewRepresentable {
    var html: String
    var baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var loadedHTML: String?
    }
}


struct PDFPreviewView: NSViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator(data: data)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            view.document = PDFDocument(data: data)
        }
    }

    final class Coordinator {
        var data: Data

        init(data: Data) {
            self.data = data
        }
    }
}


/// Editable text view that reports the `{{variable}}` under the pointer. Uses TextKit 2
/// insertion-index/rect APIs only; touching `layoutManager` would downgrade the editor.
final class HoverCodeTextView: NSTextView {
    var onHoverToken: ((VariableToken?, NSRect) -> Void)?
    private var hoverTracking: NSTrackingArea?

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
        guard let onHoverToken else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard let token = VariableTokenScanner.token(in: string, at: index) else {
            onHoverToken(nil, .zero)
            return
        }
        let screenRect = firstRect(forCharacterRange: token.range, actualRange: nil)
        onHoverToken(token, screenRect)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverToken?(nil, .zero)
    }
}
