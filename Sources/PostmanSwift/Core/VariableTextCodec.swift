import Foundation

/// Converts environment/global variables to and from the plain-text `key: value` format
/// used by the bulk editor. Lines starting with `//` are disabled rows.
enum VariableTextCodec {
    static func text(from rows: [KeyValue]) -> String {
        rows.compactMap { row in
            if row.key.isEmpty && row.value.isEmpty { return nil }
            return (row.disabled ? "// " : "") + "\(row.key): \(row.value)"
        }.joined(separator: "\n")
    }

    static func rows(from text: String) -> [KeyValue] {
        var parsed: [KeyValue] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var disabled = false
            if line.hasPrefix("//") {
                disabled = true
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty || !value.isEmpty else { continue }
                parsed.append(KeyValue(key: key, value: value, disabled: disabled))
            } else {
                parsed.append(KeyValue(key: line, value: "", disabled: disabled))
            }
        }
        return parsed
    }
}
