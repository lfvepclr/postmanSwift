import SwiftUI
import AppKit

// MARK: - Suggestions

struct VariableSuggestion: Identifiable, Hashable {
    var id: String { "\(scope).\(name)" }
    let name: String
    let value: String
    let scope: String
    let note: String?
}

struct CompletionItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let detail: String
    let insertText: String
}

struct APIMember: Identifiable {
    var id: String { name }
    let name: String
    let detail: String
}

enum APICatalog {
    static let sections: [(path: String, members: [APIMember])] = [
        ("pm", [
            APIMember(name: "environment", detail: "当前环境变量作用域：get / set / unset / clear"),
            APIMember(name: "globals", detail: "全局变量作用域：get / set / unset / clear"),
            APIMember(name: "collectionVariables", detail: "集合变量作用域：get / set / unset / clear"),
            APIMember(name: "variables", detail: "本地变量作用域：get / set / unset / clear"),
            APIMember(name: "iterationData", detail: "Runner 数据行变量"),
            APIMember(name: "request", detail: "当前请求：url / method / headers / body"),
            APIMember(name: "response", detail: "当前响应：code / status / headers / json() / text()"),
            APIMember(name: "info", detail: "执行信息：eventName / iteration / requestName"),
            APIMember(name: "cookies", detail: "Cookie 读取：get / has / toObject"),
            APIMember(name: "test", detail: "定义一条测试：pm.test(name, function () { ... })"),
            APIMember(name: "expect", detail: "断言：pm.expect(value).to.equal(...)"),
            APIMember(name: "sendRequest", detail: "发送子请求：pm.sendRequest(url, callback)"),
            APIMember(name: "visualizer", detail: "渲染可视化：pm.visualizer.set(template, data)"),
            APIMember(name: "execution", detail: "执行控制：setNextRequest(name)")
        ]),
        ("pm.environment", [
            APIMember(name: "get", detail: "读取环境变量"),
            APIMember(name: "set", detail: "写入环境变量"),
            APIMember(name: "unset", detail: "删除环境变量"),
            APIMember(name: "clear", detail: "清空当前环境变量"),
            APIMember(name: "has", detail: "判断环境变量是否存在"),
            APIMember(name: "toObject", detail: "导出全部环境变量"),
            APIMember(name: "replaceIn", detail: "替换字符串中的 {{变量}}")
        ]),
        ("pm.globals", [
            APIMember(name: "get", detail: "读取全局变量"),
            APIMember(name: "set", detail: "写入全局变量"),
            APIMember(name: "unset", detail: "删除全局变量"),
            APIMember(name: "clear", detail: "清空全局变量"),
            APIMember(name: "has", detail: "判断全局变量是否存在"),
            APIMember(name: "toObject", detail: "导出全部全局变量")
        ]),
        ("pm.variables", [
            APIMember(name: "get", detail: "按优先级读取变量（local > data > env > collection > globals）"),
            APIMember(name: "set", detail: "写入本地变量（仅本次请求/运行有效）"),
            APIMember(name: "unset", detail: "删除本地变量"),
            APIMember(name: "clear", detail: "清空本地变量"),
            APIMember(name: "has", detail: "判断变量是否存在"),
            APIMember(name: "toObject", detail: "导出当前可见变量")
        ]),
        ("pm.request", [
            APIMember(name: "url", detail: "请求 URL，可读取 query / toString()"),
            APIMember(name: "method", detail: "请求方法"),
            APIMember(name: "headers", detail: "请求头：get / add / upsert / remove"),
            APIMember(name: "body", detail: "请求体：mode / raw / toString()"),
            APIMember(name: "auth", detail: "请求认证信息")
        ]),
        ("pm.request.url", [
            APIMember(name: "toString", detail: "完整 URL 字符串"),
            APIMember(name: "get", detail: "完整 URL 字符串"),
            APIMember(name: "query", detail: "查询参数：get / has / add / upsert / remove"),
            APIMember(name: "addQueryParams", detail: "追加查询参数")
        ]),
        ("pm.request.url.query", [
            APIMember(name: "get", detail: "按名称读取查询参数（返回可 toString 的对象）"),
            APIMember(name: "has", detail: "判断查询参数是否存在"),
            APIMember(name: "add", detail: "添加查询参数"),
            APIMember(name: "upsert", detail: "添加或更新查询参数"),
            APIMember(name: "remove", detail: "删除查询参数"),
            APIMember(name: "toObject", detail: "导出查询参数对象")
        ]),
        ("pm.request.headers", [
            APIMember(name: "get", detail: "读取请求头"),
            APIMember(name: "has", detail: "判断请求头是否存在"),
            APIMember(name: "add", detail: "添加请求头"),
            APIMember(name: "upsert", detail: "添加或更新请求头"),
            APIMember(name: "remove", detail: "删除请求头"),
            APIMember(name: "toObject", detail: "导出全部请求头")
        ]),
        ("pm.response", [
            APIMember(name: "code", detail: "HTTP 状态码"),
            APIMember(name: "status", detail: "状态文本"),
            APIMember(name: "responseTime", detail: "响应耗时（毫秒）"),
            APIMember(name: "responseSize", detail: "响应大小（字节）"),
            APIMember(name: "headers", detail: "响应头：get / has / toObject"),
            APIMember(name: "text", detail: "响应体文本"),
            APIMember(name: "json", detail: "解析响应 JSON"),
            APIMember(name: "cookies", detail: "响应 Cookie"),
            APIMember(name: "reason", detail: "状态原因"),
            APIMember(name: "to", detail: "断言入口：to.have.status / header / jsonBody")
        ]),
        ("pm.response.to.have", [
            APIMember(name: "status", detail: "断言状态码：pm.response.to.have.status(200)"),
            APIMember(name: "header", detail: "断言响应头存在或等于某值"),
            APIMember(name: "jsonBody", detail: "断言 JSON 字段存在或等于某值")
        ]),
        ("pm.cookies", [
            APIMember(name: "get", detail: "读取 Cookie"),
            APIMember(name: "has", detail: "判断 Cookie 是否存在"),
            APIMember(name: "toObject", detail: "导出全部 Cookie")
        ]),
        ("pm.visualizer", [
            APIMember(name: "set", detail: "设置可视化模板与数据")
        ]),
        ("pm.execution", [
            APIMember(name: "setNextRequest", detail: "Runner 中跳转到指定请求；传 null 结束")
        ]),
        ("pm.info", [
            APIMember(name: "eventName", detail: "当前脚本事件名"),
            APIMember(name: "iteration", detail: "当前 Runner 迭代序号"),
            APIMember(name: "iterationCount", detail: "Runner 总迭代数"),
            APIMember(name: "requestName", detail: "当前请求名称"),
            APIMember(name: "requestId", detail: "当前请求 ID")
        ]),
        ("console", [
            APIMember(name: "log", detail: "输出日志到 Console"),
            APIMember(name: "info", detail: "输出信息到 Console"),
            APIMember(name: "warn", detail: "输出警告到 Console"),
            APIMember(name: "error", detail: "输出错误到 Console")
        ]),
        ("CryptoJS", [
            APIMember(name: "MD5", detail: "MD5 哈希：CryptoJS.MD5(text).toString()"),
            APIMember(name: "SHA1", detail: "SHA1 哈希"),
            APIMember(name: "SHA256", detail: "SHA256 哈希"),
            APIMember(name: "SHA512", detail: "SHA512 哈希"),
            APIMember(name: "HmacMD5", detail: "HMAC-MD5：CryptoJS.HmacMD5(text, key)"),
            APIMember(name: "HmacSHA1", detail: "HMAC-SHA1"),
            APIMember(name: "HmacSHA256", detail: "HMAC-SHA256"),
            APIMember(name: "enc", detail: "编码工具：enc.Hex / enc.Base64 / enc.Utf8")
        ])
    ]

    static let byPath: [String: [APIMember]] = Dictionary(uniqueKeysWithValues: sections.map { ($0.path, $0.members) })
}

// MARK: - Detection

enum CompletionEngine {
    static func detect(
        text: String,
        caret: Int,
        variables: [VariableSuggestion],
        scriptAPI: Bool
    ) -> (items: [CompletionItem], range: NSRange)? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let before = ns.substring(to: caret)
        let suffix = ns.substring(from: caret)

        if let start = (before as NSString).range(of: "{{", options: .backwards).location as Int?,
           start != NSNotFound {
            let prefixStart = start + 2
            let prefixRange = NSRange(location: prefixStart, length: caret - prefixStart)
            let prefix = ns.substring(with: prefixRange)
            if !prefix.contains("}}"), !prefix.contains("\n"), prefix.count <= 80 {
                let lower = prefix.lowercased()
                let matches = variables
                    .filter { lower.isEmpty || $0.name.lowercased().contains(lower) }
                    .sorted { left, right in
                        let leftStarts = left.name.lowercased().hasPrefix(lower)
                        let rightStarts = right.name.lowercased().hasPrefix(lower)
                        if leftStarts != rightStarts { return leftStarts }
                        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                    }
                let needsClose = !suffix.hasPrefix("}}")
                let items = matches.prefix(30).map { variable in
                    CompletionItem(
                        title: "{{\(variable.name)}}",
                        subtitle: "变量 · \(variable.scope)",
                        detail: variable.note.map { "\(variable.value) · \($0)" } ?? variable.value,
                        insertText: needsClose ? variable.name + "}}" : variable.name
                    )
                }
                if !items.isEmpty {
                    return (Array(items), prefixRange)
                }
            }
        }

        guard scriptAPI,
              let regex = try? NSRegularExpression(pattern: #"([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\.([A-Za-z_$][A-Za-z0-9_$]*)?$"#),
              let match = regex.firstMatch(in: before, options: [], range: NSRange(location: 0, length: caret)) else {
            return nil
        }
        let baseRange = match.range(at: 1)
        guard baseRange.location != NSNotFound else { return nil }
        let base = ns.substring(with: baseRange)
        guard let members = APICatalog.byPath[base] else { return nil }
        let partialRange = match.range(at: 2)
        let partial = partialRange.location == NSNotFound ? "" : ns.substring(with: partialRange)
        let filtered = members.filter { partial.isEmpty || $0.name.lowercased().hasPrefix(partial.lowercased()) }
        let items = filtered.map { member in
            CompletionItem(
                title: member.name,
                subtitle: "API · \(base)",
                detail: member.detail,
                insertText: member.name
            )
        }
        guard !items.isEmpty else { return nil }
        let replaceRange = partialRange.location == NSNotFound
            ? NSRange(location: caret, length: 0)
            : partialRange
        return (items, replaceRange)
    }
}

// MARK: - Popup

final class CompletionPanelModel: ObservableObject {
    @Published var items: [CompletionItem] = []
    @Published var selected = 0
}

struct CompletionListView: View {
    @ObservedObject var model: CompletionPanelModel
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onPick(index)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Theme.accent)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.tertiaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(item.detail)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if index == model.selected {
                                    Image(systemName: "return")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 42)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.selected ? Theme.accentSoft : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        if index < model.items.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .onChange(of: model.selected) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
        }
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

final class CompletionPopupController {
    static let shared = CompletionPopupController()

    private let model = CompletionPanelModel()
    private var panel: NSPanel?
    private var monitor: Any?
    private var onCommit: ((CompletionItem) -> Void)?
    private var resignObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func show(
        items: [CompletionItem],
        anchor: NSRect,
        editor: NSTextView,
        onCommit: @escaping (CompletionItem) -> Void
    ) {
        guard !items.isEmpty else {
            close()
            return
        }
        self.onCommit = onCommit
        model.items = items
        model.selected = 0

        let panel = ensurePanel()
        let rowHeight: CGFloat = 42
        let height = min(CGFloat(items.count) * rowHeight + 2, 300)
        let width: CGFloat = 400
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.minX
        var y = anchor.minY - height - 4
        if y < screen.minY + 8 {
            y = min(screen.maxY - height - 8, anchor.maxY + 4)
        }
        x = min(max(x, screen.minX + 8), screen.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()

        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible else { return event }
                switch event.keyCode {
                case 125:
                    self.move(1)
                    return nil
                case 126:
                    self.move(-1)
                    return nil
                case 36, 48:
                    self.commit()
                    return nil
                case 53:
                    self.close()
                    return nil
                default:
                    return event
                }
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.close()
            }
        }
        if editor.window?.firstResponder !== editor {
            editor.window?.makeFirstResponder(editor)
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.orderOut(nil)
        onCommit = nil
        model.items = []
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: CompletionListView(model: model, onPick: { [weak self] index in
            guard let self, self.model.items.indices.contains(index) else { return }
            self.model.selected = index
            self.commit()
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    private func commit() {
        guard model.items.indices.contains(model.selected), let onCommit else {
            close()
            return
        }
        let item = model.items[model.selected]
        close()
        onCommit(item)
    }

    static func screenRect(for textView: NSTextView, at characterIndex: Int) -> NSRect {
        guard let window = textView.window else { return .zero }
        let inset = textView.textContainerInset
        if textView.string.isEmpty {
            let rect = NSRect(x: inset.width, y: inset.height, width: 1, height: 16)
            return window.convertToScreen(textView.convert(rect, to: nil))
        }
        // Use the NSTextInputClient rect instead of `layoutManager`: touching the TextKit 1
        // layout manager on a TextKit 2 text view permanently downgrades it, which made large
        // documents spend seconds filling layout holes on the main thread.
        let length = (textView.string as NSString).length
        let index = min(max(0, characterIndex), max(0, length - 1))
        var actual = NSRange()
        let rect = textView.firstRect(
            forCharacterRange: NSRange(location: index, length: 0),
            actualRange: &actual
        )
        if rect.isEmpty {
            return window.convertToScreen(textView.convert(textView.bounds, to: nil))
        }
        return rect
    }
}

// MARK: - Variable-aware single-line field

struct VariableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 11
    var monospaced: Bool = true
    var variables: [VariableSuggestion] = []
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstMouseTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        context.coordinator.field = field
        context.coordinator.lastPushedText = text
        context.coordinator.applyHighlight(field)
        let coordinator = context.coordinator
        field.onHoverToken = { [weak field, weak coordinator] token, rect in
            guard let field else { return }
            guard let token, let coordinator else {
                VariableTooltipController.shared.close()
                return
            }
            let lookup = VariableLookup(suggestions: coordinator.parent.variables)
            VariableTooltipController.shared.show(lookup.info(for: token.name), relativeTo: rect, of: field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only push the binding into the field when the model changed from elsewhere (tab
        // switch, undo, programmatic edit). Rewriting the field editor on every keystroke
        // discarded marked text from the input method and could swallow typed characters.
        if text != context.coordinator.lastPushedText {
            context.coordinator.lastPushedText = text
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            context.coordinator.applyHighlight(field)
        } else if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
            context.coordinator.applyHighlight(field)
        }
        field.placeholderString = placeholder
        field.font = font
    }

    private var font: NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VariableTextField
        weak var field: NSTextField?
        /// Tracks the last text this field pushed into the binding, so `updateNSView` can tell
        /// an external model change (tab switch) from the echo of local typing.
        var lastPushedText: String?

        init(_ parent: VariableTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field {
                applyHighlight(field)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            lastPushedText = field.stringValue
            parent.text = field.stringValue
            applyHighlight(field)
            showCompletions(field)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            CompletionPopupController.shared.close()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if CompletionPopupController.shared.isVisible { return false }
                parent.onSubmit?()
                return true
            }
            return false
        }

        func applyHighlight(_ field: NSTextField) {
            PerformanceProbe.measure("fieldHighlight") {
                applyHighlightBody(field)
            }
        }

        private func applyHighlightBody(_ field: NSTextField) {
            let known = Set(parent.variables.map(\.name)).union(DynamicVariableCatalog.supportedNames)
            if let editor = field.currentEditor() as? NSTextView {
                let selection = editor.selectedRange()
                SyntaxHighlighter.applyVariables(to: editor, fontSize: parent.fontSize, known: known)
                editor.setSelectedRange(selection)
            } else {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: parent.monospaced
                        ? NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
                        : NSFont.systemFont(ofSize: parent.fontSize),
                    .foregroundColor: NSColor.labelColor
                ]
                let attributed = NSMutableAttributedString(string: field.stringValue, attributes: attributes)
                for token in VariableTokenScanner.tokens(in: field.stringValue) {
                    attributed.addAttribute(
                        .foregroundColor,
                        value: known.contains(token.name) ? NSColor.systemTeal : NSColor.systemRed,
                        range: token.range
                    )
                }
                field.attributedStringValue = attributed
            }
        }

        private func showCompletions(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            let caret = editor.selectedRange().location
            guard let detected = CompletionEngine.detect(
                text: editor.string,
                caret: caret,
                variables: parent.variables,
                scriptAPI: false
            ) else {
                CompletionPopupController.shared.close()
                return
            }
            let anchor = CompletionPopupController.screenRect(for: editor, at: caret)
            CompletionPopupController.shared.show(
                items: detected.items,
                anchor: anchor,
                editor: editor
            ) { [weak self, weak field] item in
                guard let editor = field?.currentEditor() as? NSTextView else { return }
                editor.textStorage?.replaceCharacters(in: detected.range, with: item.insertText)
                let caretAfter = detected.range.location + (item.insertText as NSString).length
                editor.setSelectedRange(NSRange(location: caretAfter, length: 0))
                self?.lastPushedText = editor.string
                self?.parent.text = editor.string
                if let field { self?.applyHighlight(field) }
            }
        }
    }
}

struct ScriptReferenceView: View {
    let onInsert: (String) -> Void
    @State private var query = ""

    private var sections: [(path: String, members: [APIMember])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return APICatalog.sections }
        return APICatalog.sections.compactMap { section in
            let members = section.members.filter {
                section.path.lowercased().contains(trimmed)
                    || $0.name.lowercased().contains(trimmed)
                    || $0.detail.lowercased().contains(trimmed)
            }
            return members.isEmpty ? nil : (section.path, members)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("API 文档")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("pm.* / CryptoJS")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            SearchField(text: $query, placeholder: "搜索 API")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider()
            if sections.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try another API or method name.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sections, id: \.path) { section in
                            Text(section.path)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.top, 2)
                            ForEach(section.members) { member in
                                Button {
                                    onInsert(member.name)
                                } label: {
                                    HStack(alignment: .top, spacing: 6) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(member.name)
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.primary)
                                            Text(member.detail)
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.secondaryText)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 2)
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.tertiaryText)
                                    }
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("插入 \(member.name)")
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Theme.panel)
    }
}
