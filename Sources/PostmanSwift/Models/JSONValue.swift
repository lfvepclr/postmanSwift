import Foundation

/// Order-insensitive JSON tree used for schema-extensible Postman fields.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        if case .number(let value) = self { return String(value) }
        if case .bool(let value) = self { return String(value) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var debugDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array(let values): return "[" + values.map(\.debugDescription).joined(separator: ", ") + "]"
        case .object(let values):
            return "{" + values.map { "\($0.key): \($0.value.debugDescription)" }.sorted().joined(separator: ", ") + "}"
        }
    }
}

/// Postman descriptions can be a plain string or `{ content, type }`.
struct RichText: Codable, Hashable {
    var content: String
    var type: String?

    init(_ content: String) {
        self.content = content
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let string = try? container.decode(String.self) {
            self.content = string
            self.type = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(content)
    }

    private enum CodingKeys: String, CodingKey {
        case content, type
    }
}
