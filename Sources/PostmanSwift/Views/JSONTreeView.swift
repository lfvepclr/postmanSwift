import SwiftUI
import AppKit
import PDFKit

// MARK: - Flattened rows

struct JSONTreeRow: Identifiable {
    enum Kind {
        case objectOpen(count: Int, expanded: Bool)
        case arrayOpen(count: Int, expanded: Bool)
        case close(String)
        case string(value: String, display: String, length: Int)
        case url(String)
        case pdf(base64: String, bytes: Int, preview: String, expanded: Bool)
        case pdfView(base64: String, name: String)
        case image(base64: String, bytes: Int, preview: String, expanded: Bool)
        case imageView(base64: String, name: String)
        case embeddedJSON(source: String, bytes: Int, preview: String, childCount: Int?, expanded: Bool)
        case embeddedXML(source: String, bytes: Int, preview: String, childCount: Int?, expanded: Bool)
        case xmlOpen(name: String, attributeSummary: String?, childCount: Int, expanded: Bool)
        case xmlClose(name: String)
        case xmlAttribute(name: String, value: String, display: String)
        case xmlText(value: String, display: String, length: Int)
        case number(String)
        case bool(Bool)
        case null
        case note(String)
    }

    let id: String
    let path: String
    let depth: Int
    let key: String?
    let kind: Kind
    let comma: Bool
    let isExpandable: Bool
    let isExpanded: Bool
}

extension JSONTreeRow.Kind {
    var isClosing: Bool {
        switch self {
        case .close, .xmlClose: return true
        default: return false
        }
    }
}

enum JSONTreeFlattener {
    static let rowLimit = 4_000
    static let autoExpandSourceLimit = 256 * 1_024
    static let autoExpandCountLimit = 40

    struct NodeEntry {
        let node: JSONTreeNode
        let key: String?
        let path: String
        let depth: Int
        let comma: Bool
    }

    struct FlattenResult {
        let rows: [JSONTreeRow]
        let index: [String: NodeEntry]
    }

    static func flatten(
        _ root: JSONTreeNode,
        expanded: Set<String>,
        embedded: [String: JSONTreeNode] = [:],
        sortKeys: Bool = false
    ) -> [JSONTreeRow] {
        flattenResult(root, expanded: expanded, embedded: embedded, sortKeys: sortKeys).rows
    }

    static func flattenResult(
        _ root: JSONTreeNode,
        expanded: Set<String>,
        embedded: [String: JSONTreeNode] = [:],
        sortKeys: Bool = false
    ) -> FlattenResult {
        var builder = Builder(expanded: expanded, embedded: embedded, sortKeys: sortKeys)
        builder.walk(root, key: nil, path: "$", depth: 0, comma: false)
        if builder.truncated { builder.appendTruncationNote() }
        return FlattenResult(rows: builder.rows, index: builder.index)
    }

    /// Rows for one node, shaped exactly like the slice the full flatten emits for it. Used to
    /// splice a single expand/collapse instead of re-flattening the whole document.
    static func subtreeResult(
        _ entry: NodeEntry,
        expanded: Set<String>,
        embedded: [String: JSONTreeNode],
        sortKeys: Bool
    ) -> FlattenResult {
        var builder = Builder(expanded: expanded, embedded: embedded, sortKeys: sortKeys)
        builder.walk(entry.node, key: entry.key, path: entry.path, depth: entry.depth, comma: entry.comma)
        return FlattenResult(rows: builder.rows, index: builder.index)
    }

    private struct Builder {
        let expanded: Set<String>
        let embedded: [String: JSONTreeNode]
        let sortKeys: Bool
        var rows: [JSONTreeRow] = []
        var index: [String: NodeEntry] = [:]
        var truncated = false

        init(expanded: Set<String>, embedded: [String: JSONTreeNode], sortKeys: Bool) {
            self.expanded = expanded
            self.embedded = embedded
            self.sortKeys = sortKeys
            rows.reserveCapacity(512)
        }

        mutating func append(
            _ kind: JSONTreeRow.Kind,
            path: String,
            depth: Int,
            key: String?,
            comma: Bool,
            expandable: Bool = false,
            isExpanded: Bool = false,
            node: JSONTreeNode? = nil
        ) {
            guard rows.count < JSONTreeFlattener.rowLimit else {
                truncated = true
                return
            }
            rows.append(JSONTreeRow(
                id: path,
                path: path,
                depth: depth,
                key: key,
                kind: kind,
                comma: comma,
                isExpandable: expandable,
                isExpanded: isExpanded
            ))
            if expandable, let node {
                index[path] = NodeEntry(node: node, key: key, path: path, depth: depth, comma: comma)
            }
        }

        mutating func appendTruncationNote() {
            rows.append(JSONTreeRow(
                id: "$!truncated", path: "$", depth: 0, key: nil,
                kind: .note("… 数据超过 \(JSONTreeFlattener.rowLimit) 行，已截断显示。可切换到 Raw 查看全文。"),
                comma: false, isExpandable: false, isExpanded: false
            ))
        }

        mutating func walk(_ node: JSONTreeNode, key: String?, path: String, depth: Int, comma: Bool) {
            guard rows.count < JSONTreeFlattener.rowLimit else {
                truncated = true
                return
            }
            switch node {
            case .object(let entries):
                let open = expanded.contains(path)
                let ordered = sortKeys
                    ? entries.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                    : entries
                append(.objectOpen(count: ordered.count, expanded: open), path: path, depth: depth,
                       key: key, comma: comma, expandable: true, isExpanded: open, node: node)
                guard open else { return }
                for (index, entry) in ordered.enumerated() {
                    walk(entry.value, key: entry.key,
                         path: path + "/" + entry.key + "#\(index)",
                         depth: depth + 1,
                         comma: index < ordered.count - 1)
                }
                append(.close("}"), path: path + "}", depth: depth, key: nil, comma: comma)

            case .array(let items):
                let open = expanded.contains(path)
                append(.arrayOpen(count: items.count, expanded: open), path: path, depth: depth,
                       key: key, comma: comma, expandable: true, isExpanded: open, node: node)
                guard open else { return }
                for (index, item) in items.enumerated() {
                    walk(item, key: nil, path: path + "/[\(index)]", depth: depth + 1,
                         comma: index < items.count - 1)
                }
                append(.close("]"), path: path + "]", depth: depth, key: nil, comma: comma)

            case .xmlElement(let element):
                let open = expanded.contains(path)
                let summary = JSONTreeFlattener.attributeSummary(element)
                append(.xmlOpen(name: element.name, attributeSummary: summary,
                                childCount: element.children.count, expanded: open),
                       path: path, depth: depth, key: nil, comma: comma,
                       expandable: true, isExpanded: open, node: node)
                guard open else { return }
                for attribute in element.attributes {
                    append(.xmlAttribute(name: attribute.name, value: attribute.value,
                                         display: JSONTreeFlattener.attributePreview(attribute.value)),
                           path: path + "/@\(attribute.name)", depth: depth + 1, key: nil, comma: false)
                }
                for (index, child) in element.children.enumerated() {
                    let childPath = JSONTreeFlattener.childPath(parent: path, index: index, child: child)
                    walk(child, key: nil, path: childPath, depth: depth + 1,
                         comma: index < element.children.count - 1)
                }
                append(.xmlClose(name: element.name), path: path + "</\(element.name)>",
                       depth: depth, key: nil, comma: comma)

            case .string(let value):
                walkStringLike(node, value, key: key, path: path, depth: depth, comma: comma, xmlText: false)

            case .xmlText(let value):
                walkStringLike(node, value, key: key, path: path, depth: depth, comma: comma, xmlText: true)

            case .number(let literal):
                append(.number(literal), path: path, depth: depth, key: key, comma: comma)

            case .bool(let value):
                append(.bool(value), path: path, depth: depth, key: key, comma: comma)

            case .null:
                append(.null, path: path, depth: depth, key: key, comma: comma)
            }
        }

        mutating func walkStringLike(
            _ node: JSONTreeNode,
            _ value: String,
            key: String?,
            path: String,
            depth: Int,
            comma: Bool,
            xmlText: Bool
        ) {
            let payload = PayloadClassifier.classify(value)
            switch payload {
            case .base64PDF:
                let open = expanded.contains(path)
                append(.pdf(base64: value, bytes: JSONTreeFlattener.decodedBytes(value),
                            preview: JSONTreeFlattener.mediaPreview(value), expanded: open),
                       path: path, depth: depth, key: key, comma: comma,
                       expandable: true, isExpanded: open, node: node)
                if open {
                    append(.pdfView(base64: value, name: key ?? "response"),
                           path: path + "!pdf", depth: depth + 1, key: nil, comma: false)
                }
            case .base64Image:
                let open = expanded.contains(path)
                append(.image(base64: value, bytes: JSONTreeFlattener.decodedBytes(value),
                              preview: JSONTreeFlattener.mediaPreview(value), expanded: open),
                       path: path, depth: depth, key: key, comma: comma,
                       expandable: true, isExpanded: open, node: node)
                if open {
                    append(.imageView(base64: value, name: key ?? "image"),
                           path: path + "!image", depth: depth + 1, key: nil, comma: false)
                }
            case .json, .xml:
                let isJSON = payload == .json
                let open = expanded.contains(path)
                let parsed = embedded[path]
                let count = parsed?.count
                let bytes = value.utf8.count
                let preview = JSONTreeFlattener.mediaPreview(value)
                if isJSON {
                    append(.embeddedJSON(source: value, bytes: bytes, preview: preview,
                                         childCount: count, expanded: open),
                           path: path, depth: depth, key: key, comma: comma,
                           expandable: true, isExpanded: open, node: node)
                } else {
                    append(.embeddedXML(source: value, bytes: bytes, preview: preview,
                                        childCount: count, expanded: open),
                           path: path, depth: depth, key: key, comma: comma,
                           expandable: true, isExpanded: open, node: node)
                }
                guard open else { return }
                guard let parsed else {
                    append(.note("正在解析内嵌 \(isJSON ? "JSON" : "XML")…"),
                           path: path + "!loading", depth: depth + 1, key: nil, comma: false)
                    return
                }
                switch parsed {
                case .object(let entries):
                    for (index, entry) in entries.enumerated() {
                        walk(entry.value, key: entry.key,
                             path: path + "/" + entry.key + "#\(index)",
                             depth: depth + 1,
                             comma: index < entries.count - 1)
                    }
                    append(.close("}"), path: path + "}", depth: depth, key: nil, comma: comma)
                case .array(let items):
                    for (index, item) in items.enumerated() {
                        walk(item, key: nil, path: path + "/[\(index)]", depth: depth + 1,
                             comma: index < items.count - 1)
                    }
                    append(.close("]"), path: path + "]", depth: depth, key: nil, comma: comma)
                case .xmlElement(let element):
                    for (index, child) in element.children.enumerated() {
                        walk(child, key: nil, path: path + "/<\(element.name)>[\(index)]",
                             depth: depth + 1, comma: index < element.children.count - 1)
                    }
                    append(.xmlClose(name: element.name), path: path + "</\(element.name)>",
                           depth: depth, key: nil, comma: comma)
                default:
                    append(.note("内嵌内容不是对象或数组"), path: path + "!scalar",
                           depth: depth + 1, key: nil, comma: false)
                }
            case .url:
                append(.url(value), path: path, depth: depth, key: key, comma: comma)
            case .text:
                let display = JSONTreeFlattener.stringPreview(value)
                let length = value.utf8.count
                if xmlText {
                    append(.xmlText(value: value, display: display, length: length),
                           path: path, depth: depth, key: key, comma: comma)
                } else {
                    append(.string(value: value, display: display, length: length),
                           path: path, depth: depth, key: key, comma: comma)
                }
            }
        }
    }

    /// Root and a couple of levels open by default, plus containers on the path to media. Small
    /// embedded JSON/XML strings open automatically; multi-megabyte payloads stay collapsed so the
    /// first paint never waits for them.
    static func defaultExpandedPaths(
        _ root: JSONTreeNode,
        basePath: String = "$",
        depthLimit: Int = 2
    ) -> Set<String> {
        var expanded: Set<String> = []
        var visited = 0
        var autoExpanded = 0

        @discardableResult
        func walk(_ node: JSONTreeNode, path: String, depth: Int) -> Bool {
            visited += 1
            guard visited < 50_000, depth < 80 else { return false }
            switch node {
            case .object(let entries):
                var containsMedia = false
                for (index, entry) in entries.enumerated() {
                    let childPath = path + "/" + entry.key + "#\(index)"
                    if walk(entry.value, path: childPath, depth: depth + 1) {
                        containsMedia = true
                    }
                }
                if depth <= depthLimit || containsMedia { expanded.insert(path) }
                return containsMedia
            case .array(let items):
                var containsMedia = false
                for (index, item) in items.enumerated() {
                    if walk(item, path: path + "/[\(index)]", depth: depth + 1) {
                        containsMedia = true
                    }
                }
                if depth <= depthLimit || containsMedia { expanded.insert(path) }
                return containsMedia
            case .xmlElement(let element):
                var containsMedia = false
                for (index, child) in element.children.enumerated() {
                    if walk(child, path: childPath(parent: path, index: index, child: child), depth: depth + 1) {
                        containsMedia = true
                    }
                }
                if depth <= depthLimit || containsMedia { expanded.insert(path) }
                return containsMedia
            case .string(let value), .xmlText(let value):
                let payload = PayloadClassifier.classify(value)
                switch payload {
                case .base64PDF, .base64Image:
                    expanded.insert(path)
                    return true
                case .json, .xml:
                    if value.utf8.count <= autoExpandSourceLimit, autoExpanded < autoExpandCountLimit {
                        autoExpanded += 1
                        expanded.insert(path)
                        return true
                    }
                    return false
                default:
                    return false
                }
            default:
                return false
            }
        }

        walk(root, path: basePath, depth: 0)
        return expanded
    }

    static func preparseEmbedded(
        _ root: JSONTreeNode,
        expanded: Set<String>,
        basePath: String = "$",
        seed: [String: JSONTreeNode] = [:],
        limit: Int = autoExpandCountLimit
    ) -> [String: JSONTreeNode] {
        var parsed: [String: JSONTreeNode] = [:]

        func handleString(_ value: String, path: String) -> Bool {
            if let cached = seed[path] {
                parsed[path] = cached
                walkParsed(cached, basePath: path)
                return true
            }
            guard parsed.count < limit, expanded.contains(path),
                  value.utf8.count <= autoExpandSourceLimit else { return false }
            let payload = PayloadClassifier.classify(value)
            guard payload == .json || payload == .xml,
                  let node = DocumentTreeBuilder.parseEmbedded(value, kind: payload) else { return false }
            parsed[path] = node
            walkParsed(node, basePath: path)
            return true
        }

        func walkParsed(_ node: JSONTreeNode, basePath: String) {
            switch node {
            case .object(let entries):
                for (index, entry) in entries.enumerated() {
                    let childPath = basePath + "/" + entry.key + "#\(index)"
                    if case .string(let value) = entry.value {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = entry.value {
                        _ = handleString(value, path: childPath)
                    } else {
                        walkParsed(entry.value, basePath: childPath)
                    }
                }
            case .array(let items):
                for (index, item) in items.enumerated() {
                    let childPath = basePath + "/[\(index)]"
                    if case .string(let value) = item {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = item {
                        _ = handleString(value, path: childPath)
                    } else {
                        walkParsed(item, basePath: childPath)
                    }
                }
            case .xmlElement(let element):
                for (index, child) in element.children.enumerated() {
                    let childPath = childPath(parent: basePath, index: index, child: child)
                    if case .string(let value) = child {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = child {
                        _ = handleString(value, path: childPath)
                    } else {
                        walkParsed(child, basePath: childPath)
                    }
                }
            default:
                break
            }
        }

        func walk(_ node: JSONTreeNode, path: String) {
            switch node {
            case .object(let entries):
                for (index, entry) in entries.enumerated() {
                    let childPath = path + "/" + entry.key + "#\(index)"
                    if case .string(let value) = entry.value {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = entry.value {
                        _ = handleString(value, path: childPath)
                    } else {
                        walk(entry.value, path: childPath)
                    }
                }
            case .array(let items):
                for (index, item) in items.enumerated() {
                    let childPath = path + "/[\(index)]"
                    if case .string(let value) = item {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = item {
                        _ = handleString(value, path: childPath)
                    } else {
                        walk(item, path: childPath)
                    }
                }
            case .xmlElement(let element):
                for (index, child) in element.children.enumerated() {
                    let childPath = childPath(parent: path, index: index, child: child)
                    if case .string(let value) = child {
                        _ = handleString(value, path: childPath)
                    } else if case .xmlText(let value) = child {
                        _ = handleString(value, path: childPath)
                    } else {
                        walk(child, path: childPath)
                    }
                }
            default:
                break
            }
        }

        walk(root, path: basePath)
        return parsed
    }

    static func childPath(parent: String, index: Int, child: JSONTreeNode) -> String {
        if case .xmlElement(let element) = child {
            return parent + "/<\(element.name)>[\(index)]"
        }
        return parent + "/#text[\(index)]"
    }

    private static func attributeSummary(_ element: XMLTreeElement) -> String? {
        guard !element.attributes.isEmpty else { return nil }
        let parts = element.attributes.prefix(4).map { "\($0.name)=\"\($0.value.prefix(20))\"" }
        return parts.joined(separator: " ")
    }

    private static func attributePreview(_ value: String) -> String {
        value.utf8.count > 120 ? "\"\(value.prefix(120))…\"" : "\"\(value)\""
    }

    private static func stringPreview(_ value: String) -> String {
        let limit = 180
        guard value.utf8.count > limit else { return "\"\(value)\"" }
        return "\"\(value.prefix(limit))…\""
    }

    private static func mediaPreview(_ value: String) -> String {
        let prefix = value.drop { isWhitespace($0) }.prefix(64)
        return value.utf8.count > 64 ? "\(prefix)…" : String(prefix)
    }

    private static func decodedBytes(_ base64: String) -> Int {
        max(1, base64.utf8.count / 4 * 3)
    }
}

/// Built off the main thread when a response is prepared so the view's init only copies values.
struct JSONTreePresentation {
    let id = UUID()
    let root: JSONTreeNode
    let kind: DocumentKind
    let expanded: Set<String>
    let embedded: [String: JSONTreeNode]
    let rows: [JSONTreeRow]
    let index: [String: JSONTreeFlattener.NodeEntry]
    let estimatedBytes: Int

    static func make(root: JSONTreeNode, kind: DocumentKind = .json) -> JSONTreePresentation {
        PerformanceProbe.measure("presentationBuild") {
            var expanded = JSONTreeFlattener.defaultExpandedPaths(root)
            var embedded: [String: JSONTreeNode] = [:]

            // Expand inside nested documents until no new container or embedded path appears, so a
            // base64 PDF several levels down is visible at its original position without manual work.
            for _ in 0..<3 {
                embedded = JSONTreeFlattener.preparseEmbedded(root, expanded: expanded, seed: embedded)
                let before = expanded.count
                for (path, node) in embedded {
                    expanded.formUnion(JSONTreeFlattener.defaultExpandedPaths(node, basePath: path, depthLimit: 1))
                }
                if expanded.count == before { break }
            }

            let flattened = PerformanceProbe.measure("flatten") {
                JSONTreeFlattener.flattenResult(root, expanded: expanded, embedded: embedded)
            }
            return JSONTreePresentation(
                root: root,
                kind: kind,
                expanded: expanded,
                embedded: embedded,
                rows: flattened.rows,
                index: flattened.index,
                estimatedBytes: root.estimatedBytes
            )
        }
    }
}

// MARK: - Tree view

struct JSONTreeView: View, Equatable {
    let presentation: JSONTreePresentation
    var onOpenPDF: (String, String) -> Void = { _, _ in }
    var onOpenImage: (String, String) -> Void = { _, _ in }

    /// Rows rendered per page. Paging caps one layout pass at `rowPageSize`; the lazy stack below
    /// then keeps the live view subtree close to what is actually on screen.
    private static let rowPageSize = 600

    @State private var expanded: Set<String>
    @State private var embedded: [String: JSONTreeNode]
    @State private var rows: [JSONTreeRow]
    @State private var nodeIndex: [String: JSONTreeFlattener.NodeEntry]
    @State private var loadingPaths: Set<String> = []
    @State private var search = ""
    @State private var hideEmptyValues = false
    @State private var sortKeys = false
    @State private var showingFullscreen = false
    @State private var visibleRowLimit = JSONTreeView.rowPageSize
    @State private var toolbarWidth: CGFloat = 0

    init(
        presentation: JSONTreePresentation,
        onOpenPDF: @escaping (String, String) -> Void = { _, _ in },
        onOpenImage: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.presentation = presentation
        self.onOpenPDF = onOpenPDF
        self.onOpenImage = onOpenImage
        _expanded = State(initialValue: presentation.expanded)
        _embedded = State(initialValue: presentation.embedded)
        _rows = State(initialValue: presentation.rows)
        _nodeIndex = State(initialValue: presentation.index)
    }

    static func == (lhs: JSONTreeView, rhs: JSONTreeView) -> Bool {
        lhs.presentation.id == rhs.presentation.id
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                rowStack
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.editor)
        .onChange(of: search) { _, _ in resetPaging() }
        .onChange(of: hideEmptyValues) { _, _ in resetPaging() }
        .onChange(of: presentation.id) { _, _ in resetPaging() }
        .sheet(isPresented: $showingFullscreen) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Preview")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(presentation.kind == .xml ? "XML" : "JSON")")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    Button("Close") { showingFullscreen = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                JSONTreeView(
                    presentation: presentation,
                    onOpenPDF: onOpenPDF,
                    onOpenImage: onOpenImage
                )
            }
            .frame(minWidth: 900, minHeight: 600)
            .background(Theme.editor)
        }
    }

    private var rowStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(displayedRows.prefix(visibleRowLimit)) { row in
                JSONTreeRowView(
                    row: row,
                    onOpenPDF: onOpenPDF,
                    onOpenImage: onOpenImage
                ) {
                    toggle(row)
                }
            }
            if displayedRows.count > visibleRowLimit {
                loadMoreFooter
            }
        }
    }

    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            Button {
                visibleRowLimit += Self.rowPageSize
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text("加载更多")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.accentSoft, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("再显示 \(Self.rowPageSize) 行")
            Text("已显示 \(min(visibleRowLimit, displayedRows.count)) / 共 \(displayedRows.count) 行")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.leading, 18)
        .padding(.top, 6)
    }

    private var toolbar: some View {
        let compact = toolbarWidth > 0 && toolbarWidth < 700
        return HStack(spacing: 6) {
            SearchField(text: $search, placeholder: "搜索键或值预览")
                .frame(maxWidth: 220)
                .layoutPriority(-1)
            if !search.isEmpty {
                Text("\(displayedRows.count)/\(rows.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Text("\(rows.count) 行")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize()
            ToolbarSwitch(
                title: "过滤空值",
                help: "隐藏值为 null 或空字符串的属性",
                isOn: hideEmptyValues
            ) { hideEmptyValues.toggle() }
            ToolbarSwitch(
                title: "键排序",
                help: "按字母顺序排列对象键，关闭后保持原始顺序",
                isOn: sortKeys
            ) {
                sortKeys.toggle()
                rebuild()
            }
            toolbarDivider
            actionGroup(compact: compact)
            ToolbarChip(
                glyph: .system("arrow.up.left.and.arrow.down.right"),
                title: "全屏",
                help: "全屏预览",
                showsTitle: !compact
            ) {
                showingFullscreen = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.panel)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ToolbarWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ToolbarWidthKey.self) { toolbarWidth = $0 }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.7))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }

    private func actionGroup(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ToolbarChip(
                glyph: .system("arrow.down.right.and.arrow.up.left"),
                title: "内联展开",
                help: "展开所有内联的 JSON/XML 字符串",
                showsTitle: !compact
            ) {
                expandInlineAll()
            }
            ToolbarChip(
                glyph: .unfold,
                title: "全部展开",
                help: "展开全部节点",
                showsTitle: !compact
            ) {
                expandAll()
            }
            ToolbarChip(
                glyph: .fold,
                title: "全部收起",
                help: "收起全部节点",
                isDisabled: expanded.isEmpty,
                showsTitle: !compact
            ) {
                collapseAll()
            }
        }
        .modifier(ToolbarGroupStyle())
    }

    private var displayedRows: [JSONTreeRow] {
        var result = rows
        if hideEmptyValues {
            result = result.filter { !isEmptyRow($0) }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return result }
        return result.filter { $0.matches(query) }
    }

    private func isEmptyRow(_ row: JSONTreeRow) -> Bool {
        switch row.kind {
        case .string(let value, _, _):
            return value.isEmpty
        case .xmlText(let value, _, _):
            return value.isEmpty
        case .null:
            return true
        default:
            return false
        }
    }

    private func toggle(_ row: JSONTreeRow) {
        PerformanceProbe.measure("toggle") {
            if expanded.contains(row.path) {
                collapseIncrementally(row)
                return
            }
            if let entry = nodeIndex[row.path] {
                switch row.kind {
                case .embeddedJSON, .embeddedXML:
                    // Unparsed embedded payloads still need the async parse + rebuild path.
                    if embedded[row.path] != nil, expandIncrementally(row, entry: entry) { return }
                default:
                    if expandIncrementally(row, entry: entry) { return }
                }
            }
            // Fallback: full rebuild (also drives async embedded parsing).
            let focusIndex = displayedRows.firstIndex { $0.id == row.id }
            expanded.insert(row.path)
            if case .embeddedJSON(let source, _, _, _, _) = row.kind {
                expandEmbedded(row: row, source: source, kind: .json, focusIndex: focusIndex)
            } else if case .embeddedXML(let source, _, _, _, _) = row.kind {
                expandEmbedded(row: row, source: source, kind: .xml, focusIndex: focusIndex)
            } else {
                rebuild(focusIndex: focusIndex)
            }
        }
    }

    /// Removes the visible descendants of a collapsed node and flips its disclosure state,
    /// without walking the rest of the document.
    private func collapseIncrementally(_ row: JSONTreeRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else {
            expanded.remove(row.path)
            rebuild()
            return
        }
        expanded.remove(row.path)
        rows[index] = row.settingExpanded(false)

        var end = index + 1
        while end < rows.count, rows[end].depth > row.depth { end += 1 }
        if end < rows.count, rows[end].depth == row.depth, rows[end].kind.isClosing {
            end += 1
        }
        if end > index + 1 {
            rows.removeSubrange((index + 1)..<end)
        }
        keepVisible(displayedRows.firstIndex { $0.id == row.id })
    }

    /// Inserts the rows a node reveals. Returns false when the page budget is exceeded or the
    /// node is missing from the index, so callers fall back to a full rebuild.
    private func expandIncrementally(_ row: JSONTreeRow, entry: JSONTreeFlattener.NodeEntry) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return false }
        let nextExpanded = expanded.union([row.path])
        let result = PerformanceProbe.measure("subtreeFlatten") {
            JSONTreeFlattener.subtreeResult(
                entry,
                expanded: nextExpanded,
                embedded: embedded,
                sortKeys: sortKeys
            )
        }
        guard result.rows.count > 1,
              rows.count + result.rows.count - 1 <= JSONTreeFlattener.rowLimit else { return false }
        expanded = nextExpanded
        rows[index] = result.rows[0]
        rows.insert(contentsOf: result.rows.dropFirst(), at: index + 1)
        nodeIndex.merge(result.index) { _, new in new }
        keepVisible(index)
        return true
    }

    private func expandEmbedded(row: JSONTreeRow, source: String, kind: PayloadKind, focusIndex: Int?) {
        guard embedded[row.path] == nil else {
            rebuild(focusIndex: focusIndex)
            return
        }
        if source.utf8.count <= 512_000,
           let parsed = DocumentTreeBuilder.parseEmbedded(source, kind: kind) {
            absorb(parsed, at: row.path)
            rebuild(focusIndex: focusIndex)
            return
        }
        loadingPaths.insert(row.path)
        rebuild(focusIndex: focusIndex)
        let path = row.path
        Task { @MainActor in
            let parsed = await Task.detached(priority: .userInitiated) {
                DocumentTreeBuilder.parseEmbedded(source, kind: kind)
            }.value
            loadingPaths.remove(path)
            guard expanded.contains(path) else { return }
            let index = displayedRows.firstIndex { $0.id == path }
            if let parsed {
                absorb(parsed, at: path)
            } else {
                embedded.removeValue(forKey: path)
            }
            rebuild(focusIndex: index)
        }
    }

    private func absorb(_ parsed: JSONTreeNode, at path: String) {
        embedded[path] = parsed
        expanded.formUnion(JSONTreeFlattener.defaultExpandedPaths(parsed, basePath: path, depthLimit: 1))
        let extra = JSONTreeFlattener.preparseEmbedded(
            parsed,
            expanded: expanded,
            basePath: path,
            seed: embedded
        )
        for (childPath, node) in extra {
            embedded[childPath] = node
        }
    }

    private func rebuild(focusIndex: Int? = nil) {
        PerformanceProbe.measure("rebuild") {
            let result = PerformanceProbe.measure("flatten") {
                JSONTreeFlattener.flattenResult(
                    presentation.root,
                    expanded: expanded,
                    embedded: embedded,
                    sortKeys: sortKeys
                )
            }
            rows = result.rows
            nodeIndex = result.index
        }
        // Keep already-loaded pages across expand/collapse; only a new search or a new
        // presentation resets the window.
        keepVisible(focusIndex)
    }

    private func resetPaging() {
        visibleRowLimit = Self.rowPageSize
    }

    /// Raise the window to the next page boundary covering `index`, never lowering it.
    private func keepVisible(_ index: Int?) {
        guard let index, index >= visibleRowLimit else { return }
        visibleRowLimit = (index / Self.rowPageSize + 1) * Self.rowPageSize
    }

    private func expandInlineAll() {
        PerformanceProbe.measure("inlineExpand") {
            expandInlineAllBody()
        }
    }

    private func expandInlineAllBody() {
        var parsedAny = false
        var processed = 0
        for row in rows {
            guard processed < 24 else { break }
            switch row.kind {
            case .embeddedJSON(let source, _, _, _, let open) where !open:
                processed += 1
                if embedded[row.path] != nil {
                    expanded.insert(row.path)
                    parsedAny = true
                } else if source.utf8.count <= 512_000,
                          let parsed = DocumentTreeBuilder.parseEmbedded(source, kind: .json) {
                    expanded.insert(row.path)
                    absorb(parsed, at: row.path)
                    parsedAny = true
                }
            case .embeddedXML(let source, _, _, _, let open) where !open:
                processed += 1
                if embedded[row.path] != nil {
                    expanded.insert(row.path)
                    parsedAny = true
                } else if source.utf8.count <= 512_000,
                          let parsed = DocumentTreeBuilder.parseEmbedded(source, kind: .xml) {
                    expanded.insert(row.path)
                    absorb(parsed, at: row.path)
                    parsedAny = true
                }
            default:
                break
            }
        }
        if parsedAny {
            rebuild()
        }
    }

    private func collapseAll() {
        PerformanceProbe.measure("collapseAll") {
            expanded = ["$"]
            rebuild()
        }
    }

    private func expandAll() {
        PerformanceProbe.measure("expandAll") {
            expandAllBody()
        }
    }

    private func expandAllBody() {
        var next = expanded
        var parsed = embedded
        var visited = 0
        var parsedCount = 0

        func walk(_ node: JSONTreeNode, path: String, depth: Int) {
            visited += 1
            guard visited < 6_000, depth < 80 else { return }
            switch node {
            case .object(let entries):
                next.insert(path)
                for (index, entry) in entries.enumerated() {
                    walk(entry.value, path: path + "/" + entry.key + "#\(index)", depth: depth + 1)
                }
            case .array(let items):
                next.insert(path)
                for (index, item) in items.enumerated() {
                    walk(item, path: path + "/[\(index)]", depth: depth + 1)
                }
            case .xmlElement(let element):
                next.insert(path)
                for (index, child) in element.children.enumerated() {
                    walk(child, path: JSONTreeFlattener.childPath(parent: path, index: index, child: child), depth: depth + 1)
                }
            case .string(let value), .xmlText(let value):
                let payload = PayloadClassifier.classify(value)
                guard payload == .json || payload == .xml else { return }
                next.insert(path)
                guard value.utf8.count <= 256_000, parsedCount < 40 else { return }
                if parsed[path] == nil {
                    parsed[path] = DocumentTreeBuilder.parseEmbedded(value, kind: payload)
                    parsedCount += 1
                }
                if let child = parsed[path] {
                    walk(child, path: path, depth: depth + 1)
                }
            default:
                break
            }
        }

        walk(presentation.root, path: "$", depth: 0)
        expanded = next
        embedded = parsed
        rebuild()
    }
}

extension JSONTreeRow {
    func settingExpanded(_ value: Bool) -> JSONTreeRow {
        let newKind: Kind
        switch kind {
        case .objectOpen(let count, _): newKind = .objectOpen(count: count, expanded: value)
        case .arrayOpen(let count, _): newKind = .arrayOpen(count: count, expanded: value)
        case .xmlOpen(let name, let summary, let count, _):
            newKind = .xmlOpen(name: name, attributeSummary: summary, childCount: count, expanded: value)
        case .pdf(let base64, let bytes, let preview, _):
            newKind = .pdf(base64: base64, bytes: bytes, preview: preview, expanded: value)
        case .image(let base64, let bytes, let preview, _):
            newKind = .image(base64: base64, bytes: bytes, preview: preview, expanded: value)
        case .embeddedJSON(let source, let bytes, let preview, let count, _):
            newKind = .embeddedJSON(source: source, bytes: bytes, preview: preview, childCount: count, expanded: value)
        case .embeddedXML(let source, let bytes, let preview, let count, _):
            newKind = .embeddedXML(source: source, bytes: bytes, preview: preview, childCount: count, expanded: value)
        default:
            newKind = kind
        }
        return JSONTreeRow(
            id: id,
            path: path,
            depth: depth,
            key: key,
            kind: newKind,
            comma: comma,
            isExpandable: isExpandable,
            isExpanded: value
        )
    }

    func matches(_ query: String) -> Bool {
        if let key, key.lowercased().contains(query) { return true }
        switch kind {
        case .objectOpen, .arrayOpen, .close, .null:
            return false
        case .string(_, let display, _), .xmlText(_, let display, _):
            return display.lowercased().contains(query)
        case .url(let value):
            return value.lowercased().contains(query)
        case .pdf(_, _, let preview, _), .image(_, _, let preview, _):
            return preview.lowercased().contains(query)
        case .embeddedJSON(_, _, let preview, _, _), .embeddedXML(_, _, let preview, _, _):
            return preview.lowercased().contains(query)
        case .xmlOpen(let name, let summary, _, _):
            return name.lowercased().contains(query) || (summary?.lowercased().contains(query) ?? false)
        case .xmlClose(let name):
            return name.lowercased().contains(query)
        case .xmlAttribute(let name, _, let display):
            return name.lowercased().contains(query) || display.lowercased().contains(query)
        case .pdfView(_, let name), .imageView(_, let name):
            return name.lowercased().contains(query)
        case .number(let literal):
            return literal.contains(query)
        case .bool(let value):
            return (value ? "true" : "false").contains(query)
        case .note(let text):
            return text.lowercased().contains(query)
        }
    }
}

private struct JSONTreeRowView: View {
    let row: JSONTreeRow
    var onOpenPDF: (String, String) -> Void = { _, _ in }
    var onOpenImage: (String, String) -> Void = { _, _ in }
    let onToggle: () -> Void

    private static let keyColor = Color(nsColor: .systemBlue)
    private static let stringColor = Color(nsColor: .systemGreen)
    private static let numberColor = Color(nsColor: .systemPurple)
    private static let keywordColor = Color(nsColor: .systemPink)
    private static let mediaColor = Color(red: 0.02, green: 0.6, blue: 0.42)
    private static let xmlColor = Color(nsColor: .systemIndigo)
    private static let attributeColor = Color(nsColor: .systemOrange)
    private static let urlColor = Color(nsColor: .systemTeal)

    var body: some View {
        switch row.kind {
        case .pdfView(let base64, let name):
            PDFInlineCard(base64: base64, suggestedName: name, indent: CGFloat(row.depth) * 14, onOpen: onOpenPDF)
        case .imageView(let base64, let name):
            ImageInlineCard(base64: base64, suggestedName: name, indent: CGFloat(row.depth) * 14, onOpen: onOpenImage)
        case .note(let text):
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.vertical, 6)
                .padding(.leading, CGFloat(row.depth) * 14 + 18)
        default:
            header
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 5) {
            indentation
            disclosure
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if row.isExpandable { onToggle() }
                }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 21)
        .padding(.vertical, 1)
        .contextMenu {
            if let value = copyableValue {
                Button("复制值") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            if let key = row.key {
                Button("复制键名") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
            if case .url(let value) = row.kind, let url = URL(string: value) {
                Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
            }
            if let value = copyableValue, !value.isEmpty {
                Button("复制旁路值（含引号）") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\"\(value)\"", forType: .string)
                }
            }
        }
        // One accessibility element per row: exposing every coloured Text fragment made an AX
        // snapshot of a large response take over a second. Named actions keep the behaviour.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(row.isExpandable ? .isButton : [])
        .accessibilityAction(named: Text(row.isExpanded ? "收起" : "展开")) {
            if row.isExpandable { onToggle() }
        }
        .accessibilityAction(named: Text("复制路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.path, forType: .string)
        }
    }

    private var accessibilitySummary: String {
        let keyText = row.key.map { "\($0)：" } ?? ""
        switch row.kind {
        case .objectOpen(let count, let expanded):
            return "\(keyText)对象，\(count) 个键，\(expanded ? "已展开" : "已收起")"
        case .arrayOpen(let count, let expanded):
            return "\(keyText)数组，\(count) 项，\(expanded ? "已展开" : "已收起")"
        case .close(let symbol):
            return "结束 \(symbol)"
        case .string(_, let display, let length):
            return "\(keyText)\(display)\(length > 180 ? "（共 \(length) 字符）" : "")"
        case .url(let value):
            return "\(keyText)链接 \(value)"
        case .pdf(_, let bytes, _, let expanded):
            return "\(keyText)PDF 附件，\(bytes) 字节，\(expanded ? "已展开" : "已收起")"
        case .pdfView(_, let name):
            return "PDF 预览 \(name)"
        case .image(_, let bytes, _, let expanded):
            return "\(keyText)图片，\(bytes) 字节，\(expanded ? "已展开" : "已收起")"
        case .imageView(_, let name):
            return "图片预览 \(name)"
        case .embeddedJSON(_, _, _, let childCount, let expanded):
            let count = childCount.map { "，\($0) 个键" } ?? ""
            return "\(keyText)内嵌 JSON\(count)，\(expanded ? "已展开" : "已收起")"
        case .embeddedXML(_, _, _, let childCount, let expanded):
            let count = childCount.map { "，\($0) 个子节点" } ?? ""
            return "\(keyText)内嵌 XML\(count)，\(expanded ? "已展开" : "已收起")"
        case .xmlOpen(let name, let summary, let childCount, let expanded):
            return "元素 \(name)，\(childCount) 个子节点，\(summary ?? "")\(expanded ? "，已展开" : "，已收起")"
        case .xmlClose(let name):
            return "结束元素 \(name)"
        case .xmlAttribute(let name, _, let display):
            return "属性 \(name)：\(display)"
        case .xmlText(_, let display, let length):
            return "\(display)\(length > 180 ? "（共 \(length) 字符）" : "")"
        case .number(let literal):
            return "\(keyText)\(literal)"
        case .bool(let value):
            return "\(keyText)\(value ? "true" : "false")"
        case .null:
            return "\(keyText)null"
        case .note(let text):
            return text
        }
    }

    private var indentation: some View {
        let width = CGFloat(row.depth) * 14
        return Canvas { context, size in
            guard size.width > 0 else { return }
            var path = Path()
            var x: CGFloat = 7
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += 14
            }
            context.stroke(path, with: .color(Theme.border.opacity(0.35)), lineWidth: 0.5)
        }
        .frame(width: width, height: 21)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.isExpandable {
            Button(action: onToggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 14, height: 18)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .objectOpen(let count, _):
            HStack(spacing: 5) {
                keyLabel(open: "{")
                countBadge("\(count) 键")
            }
        case .arrayOpen(let count, _):
            HStack(spacing: 5) {
                keyLabel(open: "[")
                countBadge("\(count) 项")
            }
        case .close(let symbol):
            Text(symbol).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        case .string(_, let display, let length):
            HStack(spacing: 3) {
                keyLabel(open: nil)
                Text(verbatim: display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.stringColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if length > 180 {
                    Text("(\(length) chars)")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .url(let value):
            HStack(spacing: 3) {
                keyLabel(open: nil)
                badge("URL", color: Self.urlColor)
                Button {
                    if let url = URL(string: value) { NSWorkspace.shared.open(url) }
                } label: {
                    Text(verbatim: value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.urlColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .pdf(_, let bytes, let preview, _):
            HStack(spacing: 5) {
                if let key = row.key {
                    Text("\(key): ").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.keyColor)
                }
                badge("PDF", color: Self.mediaColor)
                Text("(\(max(1, bytes / 1024)) KB)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                Text(verbatim: preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .image(_, let bytes, let preview, _):
            HStack(spacing: 5) {
                if let key = row.key {
                    Text("\(key): ").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.keyColor)
                }
                badge("IMG", color: Self.mediaColor)
                Text("(\(max(1, bytes / 1024)) KB)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                Text(verbatim: preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .embeddedJSON(_, let bytes, let preview, let childCount, _):
            embeddedRow(title: "JSON", color: Self.keyColor, bytes: bytes, preview: preview, childCount: childCount)
        case .embeddedXML(_, let bytes, let preview, let childCount, _):
            embeddedRow(title: "XML", color: Self.xmlColor, bytes: bytes, preview: preview, childCount: childCount)
        case .xmlOpen(let name, let summary, let childCount, _):
            HStack(spacing: 4) {
                Text("<\(name)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.keyColor)
                if let summary {
                    Text(verbatim: summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Self.attributeColor)
                        .lineLimit(1)
                }
                Text(">").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                countBadge("\(childCount) 子节点")
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .xmlClose(let name):
            Text("</\(name)>")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        case .xmlAttribute(let name, _, let display):
            HStack(spacing: 2) {
                Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.attributeColor)
                Text("=").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                Text(verbatim: display).font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.stringColor)
            }
        case .xmlText(_, let display, let length):
            HStack(spacing: 3) {
                Text("text").font(.system(size: 9)).foregroundStyle(Theme.tertiaryText)
                Text(verbatim: display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.stringColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if length > 180 {
                    Text("(\(length) chars)")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
                if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
            }
        case .number(let literal):
            wrappedText(verbatim: literal, color: Self.numberColor)
        case .bool(let value):
            wrappedText(verbatim: value ? "true" : "false", color: Self.keywordColor)
        case .null:
            wrappedText(verbatim: "null", color: Theme.secondaryText)
        case .note, .pdfView, .imageView:
            EmptyView()
        }
    }

    private func embeddedRow(
        title: String,
        color: Color,
        bytes: Int,
        preview: String,
        childCount: Int?
    ) -> some View {
        HStack(spacing: 5) {
            keyLabel(open: nil)
            badge(title, color: color)
            if let childCount {
                Text("(\(childCount) \(title == "XML" ? "子节点" : "键"))")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("(\(max(1, bytes / 1024)) KB)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(verbatim: preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func keyLabel(open: String?) -> some View {
        HStack(spacing: 3) {
            if let key = row.key {
                Text("\(key): ")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.keyColor)
                    .lineLimit(1)
            }
            if let open {
                Text(open)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func wrappedText(verbatim text: String, color: Color) -> some View {
        HStack(spacing: 2) {
            keyLabel(open: nil)
            Text(verbatim: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
            if row.comma { Text(",").foregroundStyle(Theme.secondaryText) }
        }
    }

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var copyableValue: String? {
        switch row.kind {
        case .string(let value, _, _), .number(let value), .xmlText(let value, _, _):
            return value
        case .url(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .pdf(let base64, _, _, _), .image(let base64, _, _, _):
            return base64
        case .embeddedJSON(let source, _, _, _, _), .embeddedXML(let source, _, _, _, _):
            return source
        case .xmlAttribute(_, let value, _):
            return value
        case .xmlOpen(let name, _, _, _), .xmlClose(let name):
            return name
        default:
            return nil
        }
    }
}

// MARK: - Inline PDF

private final class PDFAssetCache {
    static let shared = PDFAssetCache()
    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 6
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func data(forKey key: String) -> Data? {
        guard let stored = cache.object(forKey: key as NSString) else { return nil }
        return stored as Data
    }

    func store(_ data: Data, forKey key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

private final class PDFPageImageCache {
    static let shared = PDFPageImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 4
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, forKey key: String) {
        let cost = Int(max(1, image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private final class PDFPageCountCache {
    static let shared = PDFPageCountCache()
    private let cache = NSCache<NSString, NSNumber>()

    private init() { cache.countLimit = 8 }

    func count(forKey key: String) -> Int? {
        cache.object(forKey: key as NSString)?.intValue
    }

    func store(_ count: Int, forKey key: String) {
        cache.setObject(NSNumber(value: count), forKey: key as NSString)
    }
}

private final class ImageDataCache {
    static let shared = ImageDataCache()
    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 4
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func data(forKey key: String) -> Data? {
        guard let stored = cache.object(forKey: key as NSString) else { return nil }
        return stored as Data
    }

    func store(_ data: Data, forKey key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

private final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 4
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, forKey key: String) {
        let cost = Int(max(1, image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Decodes base64 images with ImageIO thumbnailing, so multi-megabyte PNG/JPEG payloads never
/// get fully decoded just to show a preview.
@MainActor
final class ImagePreviewLoader: ObservableObject {
    let maxPixel: Int

    @Published var image: NSImage?
    @Published var data: Data?
    @Published var failed = false
    @Published var isLoading = false

    private var currentKey: String?

    init(maxPixel: Int = 1_000) {
        self.maxPixel = maxPixel
    }

    static func key(for base64: String, maxPixel: Int) -> String {
        "\(base64.prefix(48)):\(base64.utf8.count)@\(maxPixel)"
    }

    func load(base64: String) {
        let key = Self.key(for: base64, maxPixel: maxPixel)
        guard currentKey != key else { return }
        currentKey = key

        if let cached = ImageThumbnailCache.shared.image(forKey: key) {
            image = cached
            data = ImageDataCache.shared.data(forKey: key)
            failed = false
            isLoading = false
            return
        }

        isLoading = true
        failed = false
        image = nil
        data = nil
        let maxPixel = self.maxPixel
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = ImageDataCache.shared.data(forKey: key)
                ?? Data(base64Encoded: Base64Image.cleaned(base64), options: .ignoreUnknownCharacters)
            guard let decoded,
                  let source = CGImageSourceCreateWithData(decoded as CFData, nil) else {
                await MainActor.run { [weak self] in
                    guard let self, self.currentKey == key else { return }
                    self.failed = true
                    self.isLoading = false
                }
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                await MainActor.run { [weak self] in
                    guard let self, self.currentKey == key else { return }
                    self.failed = true
                    self.isLoading = false
                }
                return
            }
            let rendered = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            ImageDataCache.shared.store(decoded, forKey: key)
            ImageThumbnailCache.shared.store(rendered, forKey: key)
            await MainActor.run { [weak self] in
                guard let self, self.currentKey == key else { return }
                self.data = decoded
                self.image = rendered
                self.failed = false
                self.isLoading = false
            }
        }
    }
}

struct ImageViewerPayload: Identifiable {
    let id = UUID()
    let base64: String
    let name: String
}

struct ImageViewerSheet: View {
    let payload: ImageViewerPayload
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = ImagePreviewLoader(maxPixel: 2_600)
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.accent)
                Text(payload.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("适应") { zoom = 1 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                Button {
                    zoom = max(0.5, zoom / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40)
                Button {
                    zoom = min(8, zoom * 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                if let data = loader.data {
                    Text(ContentUtilities.sizeDescription(data.count))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                    Button("Save Image") {
                        FilePanels.save(data: data, suggestedName: imageFileName)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 11))
                }
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let image = loader.image {
                ZoomablePageView(image: image, zoom: $zoom)
            } else if loader.failed {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Could not decode image",
                    message: "This base64 value does not contain a supported image."
                )
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解码图片…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 700)
        .background(Theme.editor)
        .task { loader.load(base64: payload.base64) }
    }

    private var imageFileName: String {
        let trimmed = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "image" : trimmed
        if base.contains(".") { return base }
        return base + ".png"
    }
}

/// Renders one PDF page to a bitmap off the main thread. No live PDF views are created, so
/// scrolling the tree cannot trigger PDFKit layout loops and page caches stay bounded.
@MainActor
final class PDFPagePreviewLoader: ObservableObject {
    let renderSize: CGSize

    @Published var image: NSImage?
    @Published var data: Data?
    @Published var pageCount = 0
    @Published var failed = false
    @Published var isLoading = false

    private var currentKey: String?
    private var currentPage = -1

    init(renderSize: CGSize = CGSize(width: 800, height: 1_131)) {
        self.renderSize = renderSize
    }

    static func key(for base64: String) -> String {
        "\(base64.prefix(48)):\(base64.utf8.count)"
    }

    func load(base64: String, page: Int) {
        let key = Self.key(for: base64)
        guard currentKey != key || currentPage != page else { return }
        let keyChanged = currentKey != key
        currentKey = key
        currentPage = page
        if keyChanged {
            // Never leave the previous response's PDF metadata/size on screen while the new one loads.
            pageCount = 0
            data = nil
            image = nil
        }

        let imageKey = "\(key)#\(page)@\(Int(renderSize.width))"
        if let cached = PDFPageImageCache.shared.image(forKey: imageKey) {
            image = cached
            data = PDFAssetCache.shared.data(forKey: key)
            pageCount = PDFPageCountCache.shared.count(forKey: key) ?? 0
            failed = false
            isLoading = false
            return
        }

        isLoading = true
        failed = false
        image = nil
        let renderSize = self.renderSize
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = PDFAssetCache.shared.data(forKey: key)
                ?? Data(base64Encoded: Base64PDF.cleaned(base64), options: .ignoreUnknownCharacters)
            guard let decoded,
                  decoded.starts(with: Array("%PDF".utf8)),
                  let document = PDFDocument(data: decoded) else {
                await MainActor.run { [weak self] in
                    guard let self, self.currentKey == key, self.currentPage == page else { return }
                    self.data = decoded
                    self.pageCount = 0
                    self.image = nil
                    self.failed = true
                    self.isLoading = false
                }
                return
            }
            PDFAssetCache.shared.store(decoded, forKey: key)
            let count = document.pageCount
            let index = min(max(0, page), max(0, count - 1))
            let rendered = document.page(at: index)?.thumbnail(of: renderSize, for: .mediaBox)
            PDFPageCountCache.shared.store(count, forKey: key)
            if let rendered {
                PDFPageImageCache.shared.store(rendered, forKey: imageKey)
            }
            await MainActor.run { [weak self] in
                guard let self, self.currentKey == key, self.currentPage == page else { return }
                self.data = decoded
                self.pageCount = count
                self.image = rendered
                self.failed = rendered == nil
                self.isLoading = false
            }
        }
    }
}

struct PDFViewerPayload: Identifiable {
    let id = UUID()
    let base64: String
    let name: String
}

/// Image-based PDF viewer: page navigation + pinch/button zoom, without PDFKit's PDFView caches.
struct PDFViewerSheet: View {
    let payload: PDFViewerPayload
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = PDFPagePreviewLoader(renderSize: CGSize(width: 1_400, height: 1_980))
    @State private var page = 0
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(Theme.accent)
                Text(payload.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if loader.pageCount > 1 {
                    Button {
                        page = max(0, page - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(page == 0)
                    Text("\(min(page + 1, loader.pageCount))/\(loader.pageCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                    Button {
                        page = min(loader.pageCount - 1, page + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(page >= loader.pageCount - 1)
                }
                Spacer()
                Button("适应") { zoom = 1 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .help("Fit page")
                Button {
                    zoom = max(0.5, zoom / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40)
                Button {
                    zoom = min(8, zoom * 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                if let data = loader.data {
                    Text(ContentUtilities.sizeDescription(data.count))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                    Button("Save PDF") {
                        FilePanels.save(data: data, suggestedName: pdfFileName)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 11))
                }
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: 900, height: 700)
        .background(Theme.editor)
        .task(id: page) {
            loader.load(base64: payload.base64, page: page)
        }
        .onChange(of: page) { _, _ in
            zoom = 1
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = loader.image {
            ZoomablePageView(image: image, zoom: $zoom)
        } else if loader.failed {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Could not decode PDF",
                message: "This base64 value does not contain a complete PDF document."
            )
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在渲染 PDF 页面…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pdfFileName: String {
        let trimmed = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "response" : trimmed
        return base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf"
    }
}

private struct ZoomablePageView: View {
    let image: NSImage
    @Binding var zoom: CGFloat
    @State private var gestureBase: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let fit = min(
                geometry.size.width / max(1, image.size.width),
                geometry.size.height / max(1, image.size.height)
            )
            let width = image.size.width * fit * zoom
            let height = image.size.height * fit * zoom
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if gestureBase == nil { gestureBase = zoom }
                        zoom = min(8, max(0.5, (gestureBase ?? 1) * value.magnification))
                    }
                    .onEnded { _ in
                        gestureBase = nil
                    }
            )
        }
    }
}

private struct PDFInlineCard: View {
    let base64: String
    let suggestedName: String
    let indent: CGFloat
    var onOpen: (String, String) -> Void

    @StateObject private var loader = PDFPagePreviewLoader()
    @State private var expanded = false
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                preview
            }
        }
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border.opacity(0.7), lineWidth: 0.6)
        )
        .padding(.leading, indent + 18)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .task(id: "\(expanded)-\(base64.utf8.count)-\(page)") {
            guard expanded else { return }
            loader.load(base64: base64, page: page)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("PDF 文档")
                .font(.system(size: 11, weight: .semibold))
            if loader.pageCount > 0 {
                Text("\(loader.pageCount) 页")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if loader.pageCount > 1 {
                Button {
                    page = max(0, page - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(page == 0)
                Text("\(min(page + 1, loader.pageCount))/\(loader.pageCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Button {
                    page = min(loader.pageCount - 1, page + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .disabled(page >= loader.pageCount - 1)
            }
            Spacer()
            if let data = loader.data {
                Text(ContentUtilities.sizeDescription(data.count))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Button {
                onOpen(base64, suggestedName)
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .help("Open the full PDF viewer")
            Button {
                if let data = loader.data {
                    FilePanels.save(data: data, suggestedName: pdfFileName)
                }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .disabled(loader.data == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipped()
            } else if loader.failed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    Text("无法解析这段 base64 为 PDF")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Button("打开") { onOpen(base64, suggestedName) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在渲染 PDF 页面…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: 300, height: 400)
        .padding(8)
    }

    private var pdfFileName: String {
        let trimmed = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "response" : trimmed
        return base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf"
    }
}

private struct ImageInlineCard: View {
    let base64: String
    let suggestedName: String
    let indent: CGFloat
    var onOpen: (String, String) -> Void

    @StateObject private var loader = ImagePreviewLoader(maxPixel: 1_000)
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                preview
            }
        }
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border.opacity(0.7), lineWidth: 0.6)
        )
        .padding(.leading, indent + 18)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .task(id: "\(expanded)-\(base64.utf8.count)") {
            guard expanded else { return }
            loader.load(base64: base64)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("图片")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            if let data = loader.data {
                Text(ContentUtilities.sizeDescription(data.count))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Button {
                onOpen(base64, suggestedName)
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .help("Open the full image viewer")
            Button {
                if let data = loader.data {
                    FilePanels.save(data: data, suggestedName: imageFileName)
                }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .disabled(loader.data == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipped()
            } else if loader.failed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    Text("无法解码这段 base64 图片")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Button("打开") { onOpen(base64, suggestedName) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解码图片…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: 320, height: 260)
        .padding(8)
    }

    private var imageFileName: String {
        let trimmed = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "image" : trimmed
        return base.contains(".") ? base : base + ".png"
    }
}

// MARK: - Toolbar controls

private struct ToolbarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Grouped container for a row of toolbar chips: a soft segmented surface that reads as one
/// control cluster while leaving each chip independently focusable.
private struct ToolbarGroupStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

private enum ToolbarGlyph: Equatable {
    case system(String)
    case unfold
    case fold
}

private struct ToolbarChip: View {
    let glyph: ToolbarGlyph
    let title: String
    let help: String
    var isDisabled: Bool = false
    var showsTitle: Bool = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                glyphView
                if showsTitle {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, showsTitle ? 6 : 5)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(iconColor)
        case .unfold, .fold:
            VerticalFoldGlyph(folded: glyph == .fold)
                .stroke(iconColor, style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round))
                .frame(width: 11.5, height: 11.5)
        }
    }

    private var iconColor: Color {
        isDisabled ? Theme.tertiaryText : Theme.secondaryText
    }
}

/// Unfold / fold glyphs matching the reference viewer: a vertical double arrow with side
/// dashes at the middle, arrowheads pointing outwards (unfold) or inwards (fold).
private struct VerticalFoldGlyph: Shape {
    let folded: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let w = rect.width
        let h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + w * x, y: rect.minY + h * y)
        }

        if folded {
            path.move(to: point(0.5, 0.08))
            path.addLine(to: point(0.5, 0.42))
            path.move(to: point(0.5, 0.58))
            path.addLine(to: point(0.5, 0.92))
            path.move(to: point(0.35, 0.27))
            path.addLine(to: point(0.5, 0.42))
            path.addLine(to: point(0.65, 0.27))
            path.move(to: point(0.35, 0.73))
            path.addLine(to: point(0.5, 0.58))
            path.addLine(to: point(0.65, 0.73))
        } else {
            path.move(to: point(0.5, 0.08))
            path.addLine(to: point(0.5, 0.44))
            path.move(to: point(0.5, 0.56))
            path.addLine(to: point(0.5, 0.92))
            path.move(to: point(0.35, 0.23))
            path.addLine(to: point(0.5, 0.08))
            path.addLine(to: point(0.65, 0.23))
            path.move(to: point(0.35, 0.77))
            path.addLine(to: point(0.5, 0.92))
            path.addLine(to: point(0.65, 0.77))
        }
        path.move(to: point(0.04, 0.5))
        path.addLine(to: point(0.26, 0.5))
        path.move(to: point(0.74, 0.5))
        path.addLine(to: point(0.96, 0.5))
        return path
    }
}

/// Native mini switch for options whose on/off state must be obvious at a glance.
private struct ToolbarSwitch: View {
    let title: String
    let help: String
    let isOn: Bool
    let onChange: () -> Void
    @State private var hovering = false

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in onChange() })) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(
            hovering ? Color.primary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(title)
    }
}
