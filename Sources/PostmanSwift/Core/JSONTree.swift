import Foundation

struct JSONTreeEntry {
    var key: String
    var value: JSONTreeNode
}

struct XMLAttribute: Hashable {
    var name: String
    var value: String
}

struct XMLTreeElement {
    var name: String
    var attributes: [XMLAttribute]
    var children: [JSONTreeNode]
}

/// Ordered document tree used by the response viewer. Key order follows the wire format, which
/// `JSONSerialization` cannot preserve. XML nodes live in the same enum so JSON-in-XML and
/// XML-in-JSON can share one flattener and one renderer.
indirect enum JSONTreeNode {
    case object([JSONTreeEntry])
    case array([JSONTreeNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case xmlElement(XMLTreeElement)
    case xmlText(String)

    var isContainer: Bool {
        switch self {
        case .object, .array, .xmlElement: return true
        default: return false
        }
    }

    var count: Int {
        switch self {
        case .object(let entries): return entries.count
        case .array(let items): return items.count
        case .xmlElement(let element): return element.children.count
        default: return 0
        }
    }

    /// Rough retained size used by the response memory budget. Strings dominate multi-megabyte
    /// payloads; structural overhead is intentionally ignored.
    var estimatedBytes: Int {
        switch self {
        case .string(let value), .xmlText(let value): return value.utf8.count
        case .number(let value): return value.utf8.count
        case .object(let entries):
            return entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedBytes }
        case .array(let items):
            return items.reduce(0) { $0 + $1.estimatedBytes }
        case .xmlElement(let element):
            return element.name.utf8.count
                + element.attributes.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
                + element.children.reduce(0) { $0 + $1.estimatedBytes }
        case .bool, .null:
            return 8
        }
    }
}

enum JSONTreeParser {
    /// 16 MB of source text is ~10x the largest response we render as a tree.
    static func parse(_ text: String, maxBytes: Int = 16_000_000) -> JSONTreeNode? {
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return nil }
        var parser = Parser(bytes: Array(text.utf8))
        return try? parser.parseDocument()
    }

    private enum ParseError: Error {
        case invalid
        case trailing
        case tooDeep
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        let depthLimit = 200

        mutating func parseDocument() throws -> JSONTreeNode {
            skipWhitespace()
            guard index < bytes.count else { throw ParseError.invalid }
            let first = bytes[index]
            guard first == 0x7B || first == 0x5B else { throw ParseError.invalid }
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw ParseError.trailing }
            return value
        }

        private mutating func parseValue(depth: Int) throws -> JSONTreeNode {
            guard depth < depthLimit, index < bytes.count else { throw ParseError.invalid }
            switch bytes[index] {
            case 0x7B: return try parseObject(depth: depth)
            case 0x5B: return try parseArray(depth: depth)
            case 0x22: return .string(try parseString())
            case 0x74:
                try expect("true")
                return .bool(true)
            case 0x66:
                try expect("false")
                return .bool(false)
            case 0x6E:
                try expect("null")
                return .null
            default:
                return try parseNumber()
            }
        }

        private mutating func parseObject(depth: Int) throws -> JSONTreeNode {
            index += 1
            skipWhitespace()
            var entries: [JSONTreeEntry] = []
            if peek == 0x7D {
                index += 1
                return .object(entries)
            }
            while true {
                skipWhitespace()
                guard peek == 0x22 else { throw ParseError.invalid }
                let key = try parseString()
                skipWhitespace()
                guard peek == 0x3A else { throw ParseError.invalid }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                entries.append(JSONTreeEntry(key: key, value: value))
                skipWhitespace()
                if peek == 0x2C {
                    index += 1
                    continue
                }
                guard peek == 0x7D else { throw ParseError.invalid }
                index += 1
                return .object(entries)
            }
        }

        private mutating func parseArray(depth: Int) throws -> JSONTreeNode {
            index += 1
            skipWhitespace()
            var items: [JSONTreeNode] = []
            if peek == 0x5D {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                if peek == 0x2C {
                    index += 1
                    continue
                }
                guard peek == 0x5D else { throw ParseError.invalid }
                index += 1
                return .array(items)
            }
        }

        private mutating func parseString() throws -> String {
            guard peek == 0x22 else { throw ParseError.invalid }
            index += 1
            var output: [UInt8] = []
            output.reserveCapacity(32)
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    return String(decoding: output, as: UTF8.self)
                }
                if byte == 0x5C {
                    guard index < bytes.count else { throw ParseError.invalid }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: output.append(0x22)
                    case 0x5C: output.append(0x5C)
                    case 0x2F: output.append(0x2F)
                    case 0x62: output.append(0x08)
                    case 0x66: output.append(0x0C)
                    case 0x6E: output.append(0x0A)
                    case 0x72: output.append(0x0D)
                    case 0x74: output.append(0x09)
                    case 0x75: try appendUnicodeEscape(to: &output)
                    default: throw ParseError.invalid
                    }
                } else {
                    output.append(byte)
                }
            }
            throw ParseError.invalid
        }

        private mutating func appendUnicodeEscape(to output: inout [UInt8]) throws {
            guard let unit = readHex4() else { throw ParseError.invalid }
            var scalarValue = UInt32(unit)
            if unit >= 0xD800, unit <= 0xDBFF {
                if index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                    index += 2
                    guard let low = readHex4(), low >= 0xDC00, low <= 0xDFFF else { throw ParseError.invalid }
                    scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                } else {
                    scalarValue = 0xFFFD
                }
            } else if unit >= 0xDC00, unit <= 0xDFFF {
                scalarValue = 0xFFFD
            }
            guard let scalar = Unicode.Scalar(scalarValue) else { throw ParseError.invalid }
            output.append(contentsOf: Array(String(scalar).utf8))
        }

        private mutating func readHex4() -> UInt16? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case 0x30...0x39: digit = UInt16(byte - 0x30)
                case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
                default: return nil
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        private mutating func parseNumber() throws -> JSONTreeNode {
            let start = index
            if peek == 0x2D { index += 1 }
            while index < bytes.count {
                let byte = bytes[index]
                if (0x30...0x39).contains(byte) || byte == 0x2E || byte == 0x65 || byte == 0x45 || byte == 0x2B || byte == 0x2D {
                    index += 1
                } else {
                    break
                }
            }
            guard index > start, let literal = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw ParseError.invalid
            }
            return .number(literal)
        }

        private mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw ParseError.invalid }
                index += 1
            }
        }

        private var peek: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }
    }
}

enum Base64PDF {
    static let dataURIPrefix = "data:application/pdf;base64,"

    /// Returns the approximate decoded byte count when the string is a PDF encoded as base64.
    static func byteCount(_ string: String) -> Int? {
        var body = string.drop { isWhitespace($0) }
        let head = body.prefix(64).lowercased()
        if head.hasPrefix(dataURIPrefix) {
            body = body.dropFirst(dataURIPrefix.count)
        } else if !body.hasPrefix("JVBERi") {
            return nil
        }
        guard body.utf8.count > 100 else { return nil }
        return body.utf8.count / 4 * 3
    }

    static func cleaned(_ string: String) -> String {
        var body = string.drop { isWhitespace($0) }
        if body.prefix(64).lowercased().hasPrefix(dataURIPrefix) {
            body = body.dropFirst(dataURIPrefix.count)
        }
        guard body.utf8.contains(where: isWhitespaceByte) else { return String(body) }
        var output = [UInt8]()
        output.reserveCapacity(body.utf8.count)
        for byte in body.utf8 where !isWhitespaceByte(byte) {
            output.append(byte)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

enum Base64Image {
    private static let dataURIPrefixes = [
        "data:image/png;base64,",
        "data:image/jpeg;base64,",
        "data:image/jpg;base64,",
        "data:image/gif;base64,",
        "data:image/webp;base64,"
    ]

    private static let rawPrefixes = ["iVBORw0KGgo", "/9j/", "R0lGOD", "UklGR"]

    /// Approximate decoded byte count when the string is an inline image.
    static func byteCount(_ string: String) -> Int? {
        let body = string.drop { isWhitespace($0) }
        let head = body.prefix(64).lowercased()

        var base64 = body
        var matchedDataURI = false
        for prefix in dataURIPrefixes where head.hasPrefix(prefix) {
            base64 = body.dropFirst(prefix.count)
            matchedDataURI = true
            break
        }
        if !matchedDataURI {
            guard rawPrefixes.contains(where: { body.hasPrefix($0) }) else { return nil }
        }
        guard base64.utf8.count > 100 else { return nil }
        return base64.utf8.count / 4 * 3
    }

    static func cleaned(_ string: String) -> String {
        var body = string.drop { isWhitespace($0) }
        let head = body.prefix(64).lowercased()
        for prefix in dataURIPrefixes where head.hasPrefix(prefix) {
            body = body.dropFirst(prefix.count)
            break
        }
        guard body.utf8.contains(where: isWhitespaceByte) else { return String(body) }
        var output = [UInt8]()
        output.reserveCapacity(body.utf8.count)
        for byte in body.utf8 where !isWhitespaceByte(byte) {
            output.append(byte)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Shared fast checks for inline base64 payloads. Kept byte-based so multi-megabyte values are
/// never scanned as Characters on the main thread.
func isWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
}

func isWhitespace(_ character: Character) -> Bool {
    character == " " || character == "\n" || character == "\r" || character == "\t"
}
