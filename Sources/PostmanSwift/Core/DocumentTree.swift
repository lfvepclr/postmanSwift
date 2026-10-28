import Foundation

enum DocumentKind: Equatable {
    case json
    case xml
}

enum PayloadKind: Equatable {
    case json
    case xml
    case base64PDF
    case base64Image
    case url
    case text
}

/// Cheap, prefix-only classification. Full parsing happens later and only for visible nodes.
enum PayloadClassifier {
    static func classify(_ value: String) -> PayloadKind {
        if Base64PDF.byteCount(value) != nil { return .base64PDF }
        if Base64Image.byteCount(value) != nil { return .base64Image }

        let byteCount = value.utf8.count
        guard byteCount >= 2, byteCount <= 16_000_000 else { return .text }

        let head = value.drop(while: isWhitespace).prefix(64)
        guard let first = head.first else { return .text }
        let lowerHead = head.lowercased()

        if lowerHead.hasPrefix("http://") || lowerHead.hasPrefix("https://") {
            return byteCount <= 4_096 ? .url : .text
        }
        if first == "{" || first == "[" {
            guard let last = lastNonWhitespace(value), last == "}" || last == "]" else { return .text }
            return .json
        }
        if first == "<" {
            guard let second = head.dropFirst().first,
                  second.isLetter || second == "/" || second == "?" || second == "!" else { return .text }
            if lowerHead.hasPrefix("<!doctype html") || lowerHead.hasPrefix("<html") { return .text }
            return value.utf8.contains(0x3E) ? .xml : .text
        }
        return .text
    }

    private static func lastNonWhitespace(_ value: String) -> Character? {
        var inspected = 0
        for character in value.reversed() {
            if !isWhitespace(character) { return character }
            inspected += 1
            if inspected > 256 { break }
        }
        return nil
    }
}

enum XMLTreeParser {
    static func parse(_ text: String, maxBytes: Int = 16_000_000) -> JSONTreeNode? {
        guard !text.isEmpty, text.utf8.count <= maxBytes, let data = text.data(using: .utf8) else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else { return nil }
        return .xmlElement(root)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private struct Frame {
            var name: String
            var attributes: [XMLAttribute]
            var children: [JSONTreeNode]
            var textChunks: [String]
        }

        private var stack: [Frame] = []
        var root: XMLTreeElement?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            flushText()
            let attributes = attributeDict
                .map { XMLAttribute(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
            stack.append(Frame(name: elementName, attributes: attributes, children: [], textChunks: []))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].textChunks.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
            stack[stack.count - 1].textChunks.append(text)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !stack.isEmpty else { return }
            flushText()
            let frame = stack.removeLast()
            let element = XMLTreeElement(name: frame.name, attributes: frame.attributes, children: frame.children)
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(.xmlElement(element))
            }
        }

        private func flushText() {
            guard !stack.isEmpty else { return }
            let chunks = stack[stack.count - 1].textChunks
            guard !chunks.isEmpty else { return }
            stack[stack.count - 1].textChunks.removeAll(keepingCapacity: true)
            let text = chunks.count == 1 ? chunks[0] : chunks.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            stack[stack.count - 1].children.append(.xmlText(trimmed))
        }
    }
}

enum DocumentTreeBuilder {
    static func build(text: String, mime: String?, maxBytes: Int = 16_000_000) -> (node: JSONTreeNode, kind: DocumentKind)? {
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return nil }
        let head = text.drop(while: isWhitespace).prefix(64)
        let lowerMime = (mime ?? "").lowercased()

        if head.hasPrefix("{") || head.hasPrefix("[") {
            guard let node = JSONTreeParser.parse(text, maxBytes: maxBytes) else { return nil }
            return (node, .json)
        }
        if head.hasPrefix("<"), !isHTML(head) {
            if let node = XMLTreeParser.parse(text, maxBytes: maxBytes) {
                return (node, .xml)
            }
            return nil
        }
        if lowerMime.contains("json") {
            guard let node = JSONTreeParser.parse(text, maxBytes: maxBytes) else { return nil }
            return (node, .json)
        }
        if lowerMime.contains("xml"), let node = XMLTreeParser.parse(text, maxBytes: maxBytes) {
            return (node, .xml)
        }
        return nil
    }

    static func parseEmbedded(_ source: String, kind: PayloadKind) -> JSONTreeNode? {
        switch kind {
        case .json:
            return JSONTreeParser.parse(source)
        case .xml:
            return XMLTreeParser.parse(source)
        default:
            return nil
        }
    }

    private static func isHTML(_ head: Substring) -> Bool {
        let lower = head.lowercased()
        return lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html")
    }
}

enum DocumentSerializer {
    /// Single-pass, ordered JSON output. Multi-megabyte inline media is replaced with a short
    /// placeholder so the Pretty tab stays small without re-parsing the response.
    static func prettyJSON(root: JSONTreeNode, indent: String = "  ", maxBytes: Int = 16_000_000) -> String? {
        var output = [UInt8]()
        output.reserveCapacity(1_024)
        let indentBytes = Array(indent.utf8)

        func pad(_ depth: Int) {
            for _ in 0..<depth { output.append(contentsOf: indentBytes) }
        }

        func newline(_ depth: Int) {
            output.append(0x0A)
            pad(depth)
        }

        func writeQuoted(_ value: String) {
            output.append(0x22)
            for byte in value.utf8 {
                switch byte {
                case 0x22: output.append(contentsOf: [0x5C, 0x22])
                case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: output.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: output.append(contentsOf: [0x5C, 0x72])
                case 0x09: output.append(contentsOf: [0x5C, 0x74])
                default:
                    if byte < 0x20 {
                        let hex = String(format: "%04X", byte)
                        output.append(contentsOf: Array("\\u\(hex)".utf8))
                    } else {
                        output.append(byte)
                    }
                }
            }
            output.append(0x22)
        }

        func writeStringValue(_ value: String) {
            let kind = PayloadClassifier.classify(value)
            switch kind {
            case .base64PDF:
                let kb = max(1, value.utf8.count / 4 * 3 / 1_024)
                writeQuoted("<base64 PDF data: \(kb) KB — open Preview to view>")
            case .base64Image:
                let kb = max(1, value.utf8.count / 4 * 3 / 1_024)
                writeQuoted("<base64 image data: \(kb) KB — open Preview to view>")
            default:
                writeQuoted(value)
            }
        }

        func writeKey(_ key: String) {
            writeQuoted(key)
            output.append(contentsOf: [0x3A, 0x20])
        }

        func write(_ node: JSONTreeNode, depth: Int) {
            if output.count > maxBytes { return }
            switch node {
            case .object(let entries):
                guard !entries.isEmpty else { output.append(contentsOf: [0x7B, 0x7D]); return }
                output.append(0x7B)
                for (index, entry) in entries.enumerated() {
                    newline(depth + 1)
                    writeKey(entry.key)
                    write(entry.value, depth: depth + 1)
                    if index < entries.count - 1 { output.append(0x2C) }
                }
                newline(depth)
                output.append(0x7D)
            case .array(let items):
                guard !items.isEmpty else { output.append(contentsOf: [0x5B, 0x5D]); return }
                output.append(0x5B)
                for (index, item) in items.enumerated() {
                    newline(depth + 1)
                    write(item, depth: depth + 1)
                    if index < items.count - 1 { output.append(0x2C) }
                }
                newline(depth)
                output.append(0x5D)
            case .string(let value):
                writeStringValue(value)
            case .number(let literal):
                output.append(contentsOf: literal.utf8)
            case .bool(let value):
                output.append(contentsOf: Array((value ? "true" : "false").utf8))
            case .null:
                output.append(contentsOf: Array("null".utf8))
            case .xmlElement, .xmlText:
                writeQuoted(prettyXML(root: node) ?? "")
            }
        }

        write(root, depth: 0)
        guard output.count <= maxBytes else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    static func prettyXML(root: JSONTreeNode, maxBytes: Int = 16_000_000) -> String? {
        var output = [UInt8]()
        output.reserveCapacity(1_024)

        func pad(_ depth: Int) {
            for _ in 0..<depth { output.append(contentsOf: Array("  ".utf8)) }
        }

        func writeBlock(_ block: String, depth: Int) {
            var isFirst = true
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if !isFirst { output.append(0x0A) }
                isFirst = false
                pad(depth)
                output.append(contentsOf: Array(line.utf8))
            }
            output.append(0x0A)
        }

        func writeEscaped(_ value: String, attribute: Bool) {
            for byte in value.utf8 {
                switch byte {
                case 0x26: output.append(contentsOf: Array("&amp;".utf8))
                case 0x3C: output.append(contentsOf: Array("&lt;".utf8))
                case 0x3E: output.append(contentsOf: Array("&gt;".utf8))
                case 0x22 where attribute: output.append(contentsOf: Array("&quot;".utf8))
                default: output.append(byte)
                }
            }
        }

        func write(_ node: JSONTreeNode, depth: Int) {
            if output.count > maxBytes { return }
            switch node {
            case .xmlElement(let element):
                pad(depth)
                output.append(0x3C)
                output.append(contentsOf: Array(element.name.utf8))
                for attribute in element.attributes {
                    output.append(contentsOf: Array(" \(attribute.name)=\"".utf8))
                    writeEscaped(attribute.value, attribute: true)
                    output.append(0x22)
                }
                guard !element.children.isEmpty else {
                    output.append(contentsOf: Array("/>".utf8))
                    output.append(0x0A)
                    return
                }
                output.append(0x3E)
                if element.children.count == 1,
                   case .xmlText(let text) = element.children[0],
                   !text.contains("\n"),
                   text.utf8.count <= 200,
                   PayloadClassifier.classify(text) == .text {
                    writeEscaped(text, attribute: false)
                    output.append(contentsOf: Array("</".utf8))
                    output.append(contentsOf: Array(element.name.utf8))
                    output.append(0x3E)
                    output.append(0x0A)
                    return
                }
                output.append(0x0A)
                for child in element.children {
                    write(child, depth: depth + 1)
                }
                pad(depth)
                output.append(contentsOf: Array("</".utf8))
                output.append(contentsOf: Array(element.name.utf8))
                output.append(0x3E)
                output.append(0x0A)
            case .xmlText(let text):
                let payload = PayloadClassifier.classify(text)
                switch payload {
                case .json:
                    if let node = JSONTreeParser.parse(text),
                       let block = prettyJSON(root: node, maxBytes: maxBytes) {
                        writeBlock(block, depth: depth)
                    } else {
                        pad(depth)
                        writeEscaped(text, attribute: false)
                        output.append(0x0A)
                    }
                case .xml:
                    if let node = XMLTreeParser.parse(text) {
                        write(node, depth: depth)
                    } else {
                        pad(depth)
                        writeEscaped(text, attribute: false)
                        output.append(0x0A)
                    }
                case .base64PDF:
                    pad(depth)
                    let kb = max(1, text.utf8.count / 4 * 3 / 1_024)
                    output.append(contentsOf: Array("<base64 PDF data: \(kb) KB — open Preview to view>".utf8))
                    output.append(0x0A)
                case .base64Image:
                    pad(depth)
                    let kb = max(1, text.utf8.count / 4 * 3 / 1_024)
                    output.append(contentsOf: Array("<base64 image data: \(kb) KB — open Preview to view>".utf8))
                    output.append(0x0A)
                default:
                    pad(depth)
                    writeEscaped(text, attribute: false)
                    output.append(0x0A)
                }
            default:
                if let json = prettyJSON(root: node, maxBytes: maxBytes) {
                    pad(depth)
                    output.append(contentsOf: Array(json.utf8))
                    output.append(0x0A)
                }
            }
        }

        write(root, depth: 0)
        guard output.count <= maxBytes else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
