import Foundation

enum URLUtilities {
    static func splitRaw(_ raw: String) -> (base: String, query: String?) {
        guard let index = raw.firstIndex(of: "?") else { return (raw, nil) }
        let base = String(raw[..<index])
        let query = String(raw[raw.index(after: index)...])
        return (base, query)
    }

    static func parseQuery(from raw: String) -> [KeyValue] {
        guard let query = splitRaw(raw).query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return KeyValue(key: key, value: value)
        }
    }

    static func buildRaw(base: String, params: [KeyValue]) -> String {
        let enabled = params.filter { $0.isEnabled && !($0.key.isEmpty && $0.value.isEmpty) }
        guard !enabled.isEmpty else { return base }
        let query = enabled.map { row in
            "\(encodeQueryComponent(row.key))=\(encodeQueryComponent(row.value))"
        }.joined(separator: "&")
        return base + "?" + query
    }

    /// Percent-encodes a query component but preserves Postman variable placeholders.
    static func encodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@/?")
        allowed.insert(charactersIn: "{}")
        allowed.insert(charactersIn: "%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return value }
        let lower = value.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ws://") || lower.hasPrefix("wss://")) {
            value = "http://" + value
        }
        return value
    }

    static func host(of raw: String) -> String? {
        URLComponents(string: normalize(raw))?.host
    }

    static func displayURL(base: String, params: [KeyValue]) -> String {
        let enabled = params.filter { $0.isEnabled && !($0.key.isEmpty || $0.value.isEmpty) }
        guard !enabled.isEmpty else { return base }
        let query = enabled.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return base + (base.contains("?") ? "&" : "?") + query
    }

    static func queryString(items: [KeyValue]) -> String {
        items.filter(\.isEnabled).map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}

enum ContentUtilities {
    static func isTextMime(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased() else { return false }
        return mime.hasPrefix("text/")
            || mime.contains("json")
            || mime.contains("xml")
            || mime.contains("javascript")
            || mime.contains("graphql")
            || mime.contains("x-www-form-urlencoded")
            || mime.contains("html")
            || mime.contains("csv")
    }

    static func charset(from mime: String?) -> String.Encoding {
        guard let mime, let range = mime.range(of: "charset=", options: .caseInsensitive) else {
            return .utf8
        }
        let value = mime[range.upperBound...]
            .split(separator: ";").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .lowercased() ?? "utf-8"
        switch value {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        case "utf-16": return .utf16
        default: return .utf8
        }
    }

    static func decodeText(_ data: Data, mime: String?) -> String? {
        guard !data.isEmpty else { return "" }
        if isTextMime(mime) || mime == nil {
            if let text = String(data: data, encoding: charset(from: mime)) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.prefix(4096).contains(0) { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func sizeDescription(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    static func durationDescription(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }
}

enum JSONFormatting {
    /// Pretty prints JSON while preserving the original key order.
    static func prettyPrinted(_ text: String, indent: String = "  ") -> String? {
        guard let built = DocumentTreeBuilder.build(text: text, mime: "application/json"),
              built.kind == .json else { return nil }
        return DocumentSerializer.prettyJSON(root: built.node, indent: indent)
    }


    /// Replaces very long base64 PDF string values with a short placeholder so the
    /// pretty view stays small and fast. The original response remains intact.
    static func abbreviatingBase64Strings(_ text: String) -> String {
        guard text.utf8.count <= 30_000_000 else { return text }
        guard text.contains("JVBERi0") || text.contains("application/pdf;base64") else { return text }
        let bytes = Array(text.utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 34 else {
                output.append(bytes[index])
                index += 1
                continue
            }
            var end = index + 1
            var escaped = false
            while end < bytes.count {
                let byte = bytes[end]
                if escaped {
                    escaped = false
                    end += 1
                    continue
                }
                if byte == 92 {
                    escaped = true
                    end += 1
                    continue
                }
                if byte == 34 { break }
                end += 1
            }
            guard end < bytes.count else {
                output.append(contentsOf: bytes[index...])
                break
            }
            let contentStart = index + 1
            let length = end - contentStart
            if length > 500, containsBase64Marker(bytes, start: contentStart, end: end) {
                let kb = max(1, length / 1024)
                let placeholder = "\"<base64 PDF data: \(kb) KB — open Preview to view>\""
                output.append(contentsOf: placeholder.utf8)
            } else {
                output.append(contentsOf: bytes[index...end])
            }
            index = end + 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func containsBase64Marker(_ bytes: [UInt8], start: Int, end: Int) -> Bool {
        let markers = [Array("JVBERi0".utf8), Array("application/pdf;base64".utf8)]
        for marker in markers {
            guard marker.count <= end - start else { continue }
            var index = start
            while index + marker.count <= end {
                var matches = true
                for offset in 0..<marker.count where bytes[index + offset] != marker[offset] {
                    matches = false
                    break
                }
                if matches { return true }
                index += 1
            }
        }
        return false
    }

    static func minified(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let encoded = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: encoded, encoding: .utf8)
    }

    static func xmlPrettyPrinted(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: ">\\s*<", options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let collapsed = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: ">\n<")
        var depth = 0
        var lines: [String] = []
        for rawLine in collapsed.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("</") { depth = max(0, depth - 1) }
            lines.append(String(repeating: "  ", count: depth) + line)
            if line.hasPrefix("<") && !line.hasPrefix("</") && !line.hasPrefix("<?") && !line.hasPrefix("<!")
                && !line.hasSuffix("/>") && !line.contains("</") {
                depth += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
