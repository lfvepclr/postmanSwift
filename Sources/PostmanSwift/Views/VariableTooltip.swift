import SwiftUI
import AppKit

// MARK: - Tokens

struct VariableToken: Equatable {
    let name: String
    let range: NSRange
}

enum VariableTokenScanner {
    private static let regex = try! NSRegularExpression(pattern: #"\{\{([^{}\n]+)\}\}"#)

    static func tokens(in text: String) -> [VariableToken] {
        let ns = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return VariableToken(name: ns.substring(with: match.range(at: 1)), range: match.range)
        }
    }

    static func token(in text: String, at index: Int) -> VariableToken? {
        tokens(in: text).first { index >= $0.range.location && index < NSMaxRange($0.range) }
    }

    /// Hit test for a single-line text field: measures token widths with the field's font.
    static func hit(atX x: CGFloat, text: String, font: NSFont) -> (token: VariableToken, rect: NSRect)? {
        guard !text.isEmpty, x >= 0 else { return nil }
        let ns = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for token in tokens(in: text) {
            let prefix = ns.substring(to: token.range.location) as NSString
            let tokenText = ns.substring(with: token.range) as NSString
            let start = prefix.size(withAttributes: attributes).width
            let width = tokenText.size(withAttributes: attributes).width
            if x >= start - 1, x <= start + width + 1 {
                return (token, NSRect(x: start, y: 0, width: max(2, width), height: 16))
            }
        }
        return nil
    }
}

// MARK: - Lookup

struct VariableHoverInfo {
    enum Kind {
        case variable(scope: String, value: String, note: String?)
        case dynamic(DynamicVariable)
        case unknown
    }

    let name: String
    let kind: Kind

    var isUnknown: Bool {
        if case .unknown = kind { return true }
        return false
    }
}

struct VariableLookup {
    let suggestions: [VariableSuggestion]

    func info(for name: String) -> VariableHoverInfo {
        if name.hasPrefix("$"), let dynamic = DynamicVariableCatalog.byName[name] {
            return VariableHoverInfo(name: name, kind: .dynamic(dynamic))
        }
        let matches = suggestions.filter { $0.name == name }
        if let exact = matches.first(where: { $0.scope != "Dynamic" }) ?? matches.first {
            return VariableHoverInfo(
                name: name,
                kind: .variable(scope: exact.scope, value: exact.value, note: exact.note)
            )
        }
        return VariableHoverInfo(name: name, kind: .unknown)
    }

    var knownNames: Set<String> {
        Set(suggestions.map(\.name)).union(DynamicVariableCatalog.supportedNames)
    }
}

// MARK: - Popover

@MainActor
final class VariableTooltipController {
    static let shared = VariableTooltipController()

    private var popover: NSPopover?
    private var currentKey: String?

    func show(_ info: VariableHoverInfo, relativeTo rect: NSRect, of view: NSView) {
        let key = "\(info.name)|\(rect.minX)|\(rect.minY)|\(view.hashValue)"
        if currentKey == key, popover?.isShown == true { return }
        currentKey = key

        let popover = self.popover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            self.popover = popover
            return popover
        }()
        popover.contentViewController = NSHostingController(rootView: VariableTooltipView(info: info))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        currentKey = nil
        popover?.performClose(nil)
    }
}

private struct VariableTooltipView: View {
    let info: VariableHoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("{{\(info.name)}}")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(info.isUnknown ? Theme.danger : Color(nsColor: .systemTeal))
                Spacer()
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(info.isUnknown ? Theme.danger : Theme.tertiaryText)
            }
            switch info.kind {
            case .variable(let scope, let value, let note):
                Text(scope)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3)
                }
            case .dynamic(let dynamic):
                Text("动态变量")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                Text("示例：\(dynamic.example)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text(dynamic.description)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
            case .unknown:
                Text("未定义变量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.danger)
                Text("当前环境、Globals、集合与本地变量里都没有这个名称，发送时会原样保留。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
    }

    private var badge: String {
        switch info.kind {
        case .variable: return "VARIABLE"
        case .dynamic: return "DYNAMIC"
        case .unknown: return "MISSING"
        }
    }
}

// MARK: - Highlighting

extension SyntaxHighlighter {
    /// Colors `{{...}}` tokens; unknown names turn red so missing variables are obvious.
    static func applyVariableColors(to textView: NSTextView, known: Set<String>) {
        guard let storage = textView.textStorage, storage.length <= 200_000 else { return }
        let text = textView.string
        for token in VariableTokenScanner.tokens(in: text) {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: known.contains(token.name) ? NSColor.systemTeal : NSColor.systemRed,
                range: token.range
            )
        }
    }
}
