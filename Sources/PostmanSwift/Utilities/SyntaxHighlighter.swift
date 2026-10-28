import AppKit

enum SyntaxLanguage: String {
    case plain
    case json
    case javascript
    case xml
    case html
    case shell
    case python
    case swift
    case go
    case java
    case graphql

    static func detect(mime: String?, text: String?) -> SyntaxLanguage {
        let lower = (mime ?? "").lowercased()
        if lower.contains("json") { return .json }
        if lower.contains("javascript") { return .javascript }
        if lower.contains("html") { return .html }
        if lower.contains("xml") { return .xml }
        guard let text else { return .plain }
        // Only sniff the head of the payload; trimming or lowercasing a multi-megabyte body on the
        // main thread is enough to stall the response view.
        let sample = text.utf8.count > 8_192 ? String(text.prefix(8_192)) : text
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(64).lowercased()
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
        if trimmed.hasPrefix("<") { return .xml }
        return .plain
    }

    static func from(rawLanguage: RawLanguage) -> SyntaxLanguage {
        switch rawLanguage {
        case .json: return .json
        case .xml: return .xml
        case .html: return .html
        case .javascript: return .javascript
        case .text: return .plain
        }
    }

    static func from(codeLanguage: CodeLanguage) -> SyntaxLanguage {
        switch codeLanguage {
        case .curl: return .shell
        case .swift: return .swift
        case .python: return .python
        case .javascript: return .javascript
        case .go: return .go
        case .java: return .java
        case .csharp: return .java
        case .kotlin: return .java
        case .php, .ruby, .rust: return .plain
        case .powershell: return .shell
        case .http: return .plain
        }
    }
}

struct SyntaxToken {
    var range: NSRange
    var color: NSColor
}

enum SyntaxHighlighter {
    private static let lock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        let length = (text as NSString).length
        guard length <= 400_000 else { return [] }
        var tokens: [SyntaxToken] = []

        func add(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = [], group: Int = 0) {
            guard let regex = cached(pattern, options: options) else { return }
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: length))
            for match in matches {
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= length else { continue }
                tokens.append(SyntaxToken(range: range, color: color))
            }
        }

        switch language {
        case .json:
            add(#""(?:\\.|[^"\\])*""#, color: .systemRed)
            add(#"("(?:\\.|[^"\\])*")\s*:"#, color: .systemBlue, group: 1)
            add(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemPurple)
            add(#"\b(?:true|false|null)\b"#, color: .systemPink)

        case .javascript, .graphql:
            add(#"\b-?\d+(?:\.\d+)?\b"#, color: .systemPurple)
            add(#"\b(?:true|false|null|undefined)\b"#, color: .systemPink)
            add(#"\b(?:var|let|const|function|return|if|else|for|while|do|switch|case|break|continue|new|this|try|catch|finally|throw|typeof|instanceof|in|of|class|extends|super|async|await|yield|delete|void|with|debugger|import|export|from|default|query|mutation|subscription|fragment|on|type|input|enum|interface|union|scalar|schema)\b"#, color: .systemPink)
            add(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, color: .systemRed)
            add(#"//[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])
            add(#"/\*[\s\S]*?\*/"#, color: .systemGreen)

        case .xml, .html:
            add(#"</?[A-Za-z][A-Za-z0-9:._-]*"#, color: .systemBlue)
            add(#"(?<=<)[A-Za-z][A-Za-z0-9:._-]*"#, color: .systemBlue)
            add(#"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#, color: .systemOrange)
            add(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: .systemRed)
            add(#"<!DOCTYPE[^>]*>"#, color: .systemPurple, options: [.caseInsensitive])
            add(#"<!--[\s\S]*?-->"#, color: .systemGreen)

        case .shell:
            add(#"(?:^|\s)(--?[A-Za-z0-9][A-Za-z0-9_-]*)"#, color: .systemTeal, group: 1)
            add(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, color: .systemPurple)
            add(#"'[^']*'|"(?:\\.|[^"\\])*""#, color: .systemRed)
            add(#"(?:^|\s)#[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])

        case .python:
            add(#"\b(?:def|class|return|if|elif|else|for|while|in|not|and|or|import|from|as|try|except|finally|with|lambda|yield|async|await|pass|break|continue|None|True|False|self)\b"#, color: .systemPink)
            add(#"-?\b\d+(?:\.\d+)?\b"#, color: .systemPurple)
            add(#"[rbfu]{0,2}'''[\s\S]*?'''|[rbfu]{0,2}"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: .systemRed)
            add(#"#[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])

        case .swift:
            add(#"\b(?:let|var|func|return|if|else|guard|for|while|repeat|switch|case|default|break|continue|class|struct|enum|protocol|extension|import|init|deinit|self|super|nil|true|false|try|catch|throw|throws|async|await|public|private|internal|static|mutating|where|in|as|is|some|any)\b"#, color: .systemPink)
            add(#"\b\d+(?:\.\d+)?\b"#, color: .systemPurple)
            add(#""(?:\\.|[^"\\])*""#, color: .systemRed)
            add(#"//[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])
            add(#"/\*[\s\S]*?\*/"#, color: .systemGreen)

        case .go:
            add(#"\b(?:package|import|func|return|if|else|for|range|switch|case|default|break|continue|var|const|type|struct|interface|map|chan|go|defer|select|nil|true|false|string|int|int64|float64|bool|byte|error)\b"#, color: .systemPink)
            add(#"\b\d+(?:\.\d+)?\b"#, color: .systemPurple)
            add(#""(?:\\.|[^"\\])*"|`[^`]*`"#, color: .systemRed)
            add(#"//[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])
            add(#"/\*[\s\S]*?\*/"#, color: .systemGreen)

        case .java:
            add(#"\b(?:public|private|protected|static|final|class|interface|extends|implements|new|return|if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|throws|void|int|long|double|float|boolean|char|String|null|true|false|import|package)\b"#, color: .systemPink)
            add(#"\b\d+(?:\.\d+)?\b"#, color: .systemPurple)
            add(#""(?:\\.|[^"\\])*""#, color: .systemRed)
            add(#"//[^\n]*"#, color: .systemGreen, options: [.anchorsMatchLines])
            add(#"/\*[\s\S]*?\*/"#, color: .systemGreen)

        case .plain:
            break
        }

        add(#"\{\{[^{}\n]+\}\}"#, color: .systemTeal)
        return tokens
    }

    static func applyVariables(to textView: NSTextView, fontSize: CGFloat, known: Set<String>? = nil) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let length = (text as NSString).length
        let full = NSRange(location: 0, length: length)
        let selection = textView.selectedRanges
        let base = baseAttributes(fontSize: fontSize)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        for variable in VariableTokenScanner.tokens(in: text) {
            guard NSMaxRange(variable.range) <= length else { continue }
            let isKnown = known?.contains(variable.name) ?? true
            storage.addAttribute(
                .foregroundColor,
                value: isKnown ? NSColor.systemTeal : NSColor.systemRed,
                range: variable.range
            )
        }
        storage.endEditing()
        textView.typingAttributes = base
        if textView.isEditable {
            textView.selectedRanges = selection
        }
    }

    static func apply(to textView: NSTextView, language: SyntaxLanguage, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let length = (text as NSString).length
        let full = NSRange(location: 0, length: length)
        let selection = textView.selectedRanges
        let base = baseAttributes(fontSize: fontSize)

        storage.beginEditing()
        storage.setAttributes(base, range: full)
        for token in tokens(in: text, language: language) {
            guard NSMaxRange(token.range) <= length else { continue }
            storage.addAttribute(.foregroundColor, value: token.color, range: token.range)
        }
        storage.endEditing()

        textView.typingAttributes = base
        if textView.isEditable {
            textView.selectedRanges = selection
        }
    }

    private static func cached(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = regexCache[key] { return existing }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache[key] = regex
        return regex
    }
}
