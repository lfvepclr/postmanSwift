import Foundation

struct EmbeddedPDF: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let data: Data

    var byteCount: Int { data.count }

    static func == (lhs: EmbeddedPDF, rhs: EmbeddedPDF) -> Bool {
        lhs.name == rhs.name && lhs.data == rhs.data
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(data.count)
    }
}

enum PDFExtractor {
    private static let maxPDFBytes = 60 * 1024 * 1024
    private static let maxTotalBytes = 32 * 1024 * 1024

    static func extract(text: String?, mime: String?, body: Data) -> [EmbeddedPDF] {
        if body.starts(with: Data("%PDF-".utf8)) || (mime ?? "").lowercased().contains("pdf") {
            return [EmbeddedPDF(name: "response.pdf", data: body)]
        }
        guard let text, !text.isEmpty, text.utf8.count <= 30_000_000 else { return [] }

        var results: [EmbeddedPDF] = []
        var totalBytes = 0

        func append(_ data: Data, name: String) {
            guard data.count <= maxPDFBytes, totalBytes + data.count <= maxTotalBytes,
                  data.starts(with: Data("%PDF-".utf8)) else { return }
            totalBytes += data.count
            results.append(EmbeddedPDF(name: name, data: data))
        }

        // Reuse the ordered parser instead of JSONSerialization: one parse, no duplicate object
        // graph, and no base64 decode for strings that cannot be a PDF.
        if let node = JSONTreeParser.parse(text) {
            walk(node, path: "pdf", append: append)
        } else if let node = XMLTreeParser.parse(text) {
            walk(node, path: "xml", append: append)
        }

        if results.isEmpty {
            let pattern = #"(?:data:application/pdf;base64,)?[A-Za-z0-9+/=\s]{400,}"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = text as NSString
                for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                    let raw = ns.substring(with: match.range)
                    if let data = decodeBase64(raw) {
                        append(data, name: "embedded.pdf")
                    }
                }
            }
        }

        return Array(results.prefix(5))
    }

    private static func walk(_ node: JSONTreeNode, path: String, append: (Data, String) -> Void) {
        switch node {
        case .string(let value), .xmlText(let value):
            guard isPDFCandidate(value), let data = decodeBase64(value) else { return }
            append(data, path)
        case .object(let entries):
            for entry in entries {
                walk(entry.value, path: path.isEmpty ? entry.key : "\(path).\(entry.key)", append: append)
            }
        case .array(let items):
            for (index, child) in items.enumerated() {
                walk(child, path: "\(path)[\(index)]", append: append)
            }
        case .xmlElement(let element):
            for child in element.children {
                walk(child, path: path.isEmpty ? element.name : "\(path).\(element.name)", append: append)
            }
        default:
            break
        }
    }

    private static func isPDFCandidate(_ value: String) -> Bool {
        let head = value.drop { isWhitespace($0) }.prefix(64)
        return head.hasPrefix("JVBERi") || head.lowercased().hasPrefix(Base64PDF.dataURIPrefix)
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("data:") {
            guard let comma = raw.firstIndex(of: ",") else { return nil }
            let header = raw[..<comma].lowercased()
            guard header.contains("base64"), header.contains("pdf") else { return nil }
            raw = String(raw[raw.index(after: comma)...])
        }
        raw = raw.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard raw.count > 32 else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]) else { return nil }
        return data.starts(with: Data("%PDF-".utf8)) ? data : nil
    }
}
