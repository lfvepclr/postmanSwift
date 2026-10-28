import Foundation

// MARK: - Key / value row

/// Shared row type for headers, query params, form fields and variables.
/// `id` is runtime-only and never written to exported collections.
struct KeyValue: Identifiable, Hashable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var disabled: Bool = false
    var description: RichText?
    var type: String?
    var src: JSONValue?

    init(key: String = "", value: String = "", disabled: Bool = false) {
        self.key = key
        self.value = value
        self.disabled = disabled
    }

    var isEnabled: Bool { !disabled }
    var isFile: Bool { type?.lowercased() == "file" }

    func resolved(_ context: VariableContext) -> KeyValue {
        var copy = self
        copy.key = context.resolve(key)
        copy.value = context.resolve(value)
        return copy
    }
}

extension KeyValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, value, disabled, enabled, description, type, src
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.key = Self.flexibleString(container, forKey: .key) ?? ""
        self.value = Self.flexibleString(container, forKey: .value) ?? ""
        if let disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) {
            self.disabled = disabled
        } else if let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) {
            self.disabled = !enabled
        } else {
            self.disabled = false
        }
        self.description = try container.decodeIfPresent(RichText.self, forKey: .description)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.src = try container.decodeIfPresent(JSONValue.self, forKey: .src)
    }

    private static func flexibleString(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let value = try? container.decode(JSONValue.self, forKey: key) {
            return value.stringValue ?? value.debugDescription
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
        if disabled { try container.encode(true, forKey: .disabled) }
        if let description, !description.content.isEmpty {
            try container.encode(description.content, forKey: .description)
        }
        if let type { try container.encode(type, forKey: .type) }
        if let src { try container.encode(src, forKey: .src) }
    }
}

// MARK: - Auth

struct Auth: Hashable {
    var type: String?
    /// Postman stores each auth method's fields as its own array, e.g. `basic: [{key,value}]`.
    var params: [String: [KeyValue]]

    init(type: String? = nil, params: [String: [KeyValue]] = [:]) {
        self.type = type
        self.params = params
    }

    static let none = Auth(type: "noauth")
    static let inherit = Auth(type: "inherit")

    var isInherit: Bool { type == "inherit" }
    var isNoAuth: Bool { type == nil || type == "noauth" }

    func value(_ key: String, method: String? = nil) -> String? {
        guard let method = method ?? type, let rows = params[method] else { return nil }
        return rows.first(where: { $0.isEnabled && $0.key == key })?.value
    }

    mutating func setValue(_ value: String, for key: String, method: String? = nil) {
        guard let method = method ?? type else { return }
        var rows = params[method] ?? []
        if let index = rows.firstIndex(where: { $0.key == key }) {
            rows[index].value = value
        } else {
            rows.append(KeyValue(key: key, value: value))
        }
        params[method] = rows
    }

    mutating func ensureRows(_ keys: [String], method: String? = nil) {
        guard let method = method ?? type else { return }
        var rows = params[method] ?? []
        for key in keys where !rows.contains(where: { $0.key == key }) {
            rows.append(KeyValue(key: key, value: ""))
        }
        params[method] = rows
    }
}

extension Auth: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var type: String?
        var params: [String: [KeyValue]] = [:]
        for key in container.allKeys {
            if key.stringValue == "type" {
                type = try container.decodeIfPresent(String.self, forKey: key)
                continue
            }
            if let rows = try? container.decode([KeyValue].self, forKey: key) {
                params[key.stringValue] = rows
            } else if let object = try? container.decode([String: JSONValue].self, forKey: key) {
                params[key.stringValue] = object.map { KeyValue(key: $0.key, value: $0.value.stringValue ?? $0.value.debugDescription) }
            }
        }
        self.type = type
        self.params = params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        if let type, let key = DynamicKey(stringValue: "type") {
            try container.encode(type, forKey: key)
        }
        for (method, rows) in params {
            guard let key = DynamicKey(stringValue: method), !rows.isEmpty else { continue }
            try container.encode(rows, forKey: key)
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

// MARK: - URL

struct URLDef: Codable, Hashable {
    var raw: String = ""
    var query: [KeyValue]?
    var variable: [KeyValue]?
    var `protocol`: String?
    var host: [String]?
    var path: [String]?
    var port: String?
    var hash: String?

    init(raw: String = "", query: [KeyValue]? = nil) {
        self.raw = raw
        self.query = query
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let string = try? container.decode(String.self) {
            self.raw = string
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = try container.decodeIfPresent(String.self, forKey: .raw) ?? ""
        self.query = try container.decodeIfPresent([KeyValue].self, forKey: .query)
        self.variable = try container.decodeIfPresent([KeyValue].self, forKey: .variable)
        self.protocol = try container.decodeIfPresent(String.self, forKey: .protocol)
        self.host = Self.decodeStringArray(container, forKey: .host, separator: ".")
        self.path = Self.decodeStringArray(container, forKey: .path, separator: "/")
        if let portString = try? container.decode(String.self, forKey: .port) {
            self.port = portString
        } else if let portNumber = try? container.decode(Int.self, forKey: .port) {
            self.port = String(portNumber)
        } else {
            self.port = nil
        }
        self.hash = try container.decodeIfPresent(String.self, forKey: .hash)
        if self.raw.isEmpty {
            self.raw = Self.rebuildRaw(protocol: self.protocol, host: self.host, path: self.path, port: self.port, query: self.query)
        }
        if self.query == nil {
            let parsed = URLUtilities.parseQuery(from: self.raw)
            if !parsed.isEmpty { self.query = parsed }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        if let query, !query.isEmpty { try container.encode(query, forKey: .query) }
        if let variable, !variable.isEmpty { try container.encode(variable, forKey: .variable) }
    }

    private enum CodingKeys: String, CodingKey {
        case raw, query, variable, `protocol`, host, path, port, hash
    }

    private static func decodeStringArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        separator: Character
    ) -> [String]? {
        if let array = try? container.decode([String].self, forKey: key) {
            return array
        }
        if let string = try? container.decode(String.self, forKey: key) {
            return string.split(separator: separator).map(String.init)
        }
        return nil
    }

    private static func rebuildRaw(protocol proto: String?, host: [String]?, path: [String]?, port: String?, query: [KeyValue]?) -> String {
        var result = ""
        if let proto, !proto.isEmpty { result += "\(proto)://" }
        result += (host ?? []).joined(separator: ".")
        if let port, !port.isEmpty { result += ":\(port)" }
        if let path, !path.isEmpty { result += "/" + path.joined(separator: "/") }
        let enabled = (query ?? []).filter { $0.isEnabled && !$0.key.isEmpty }
        if !enabled.isEmpty {
            result += "?" + enabled.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        return result
    }
}

// MARK: - Body

struct RawBodyOptions: Codable, Hashable {
    var language: String?
    var headerFamily: String?
}

struct BodyOptions: Codable, Hashable {
    var raw: RawBodyOptions?
}

struct GraphQLBody: Codable, Hashable {
    var query: String?
    var variables: JSONValue?
}

struct FileBody: Codable, Hashable {
    var src: JSONValue?
    var content: String?
}

struct RequestBody: Codable, Hashable {
    var mode: String?
    var raw: String?
    var urlencoded: [KeyValue]?
    var formdata: [KeyValue]?
    var graphql: GraphQLBody?
    var file: FileBody?
    var options: BodyOptions?
    var disabled: Bool?
}

// MARK: - Scripts / events

struct PMEvent: Codable, Hashable {
    var listen: String
    var script: Script?

    struct Script: Codable, Hashable {
        var type: String?
        var exec: [String]?
        var src: String?
        var id: String?
        var name: String?

        enum CodingKeys: String, CodingKey {
            case type, exec, src, id, name
        }

        init(type: String? = nil, exec: [String]? = nil, src: String? = nil, id: String? = nil, name: String? = nil) {
            self.type = type
            self.exec = exec
            self.src = src
            self.id = id
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
            self.src = try container.decodeIfPresent(String.self, forKey: .src)
            self.id = try container.decodeIfPresent(String.self, forKey: .id)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
            if let lines = try? container.decode([String].self, forKey: .exec) {
                self.exec = lines
            } else if let line = try? container.decode(String.self, forKey: .exec) {
                self.exec = [line]
            } else {
                self.exec = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type ?? "text/javascript", forKey: .type)
            try container.encodeIfPresent(exec, forKey: .exec)
            try container.encodeIfPresent(src, forKey: .src)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
        }
    }

    var source: String {
        (script?.exec ?? []).joined(separator: "\n")
    }
}

// MARK: - Request / item / collection

struct RequestDef: Codable, Hashable {
    var method: String?
    var header: [KeyValue]?
    var body: RequestBody?
    var url: URLDef?
    var auth: Auth?
    var description: RichText?

    init(method: String = "GET", url: String = "", header: [KeyValue]? = nil, body: RequestBody? = nil, auth: Auth? = nil) {
        self.method = method
        self.url = URLDef(raw: url)
        self.header = header
        self.body = body
        self.auth = auth
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let string = try? container.decode(String.self) {
            self.method = "GET"
            self.url = URLDef(raw: string)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try container.decodeIfPresent(String.self, forKey: .method)
        self.header = try container.decodeIfPresent([KeyValue].self, forKey: .header)
        self.body = try container.decodeIfPresent(RequestBody.self, forKey: .body)
        self.url = try container.decodeIfPresent(URLDef.self, forKey: .url)
        self.auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
        self.description = try container.decodeIfPresent(RichText.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey {
        case method, header, body, url, auth, description
    }

    var rawURL: String { url?.raw ?? "" }
}

struct CollectionItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var item: [CollectionItem]?
    var request: RequestDef?
    var auth: Auth?
    var event: [PMEvent]?
    var variable: [KeyValue]?
    var description: RichText?
    var protocolProfileBehavior: [String: JSONValue]?

    init(name: String, request: RequestDef? = nil, item: [CollectionItem]? = nil) {
        self.id = UUID().uuidString
        self.name = name
        self.request = request
        self.item = item
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        self.item = try container.decodeIfPresent([CollectionItem].self, forKey: .item)
        self.request = try container.decodeIfPresent(RequestDef.self, forKey: .request)
        self.auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
        self.event = try container.decodeIfPresent([PMEvent].self, forKey: .event)
        self.variable = try container.decodeIfPresent([KeyValue].self, forKey: .variable)
        self.description = try container.decodeIfPresent(RichText.self, forKey: .description)
        self.protocolProfileBehavior = try container.decodeIfPresent([String: JSONValue].self, forKey: .protocolProfileBehavior)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, item, request, auth, event, variable, description, protocolProfileBehavior
    }

    var isFolder: Bool { request == nil }
    var subtitle: String {
        if let request { return "\(request.method ?? "GET") \(request.rawURL)" }
        return "\(item?.count ?? 0) requests"
    }

    var preRequestScript: String {
        event?.first(where: { $0.listen == "prerequest" })?.source ?? ""
    }

    var testScript: String {
        event?.first(where: { $0.listen == "test" })?.source ?? ""
    }

    mutating func setPreRequestScript(_ source: String) {
        setScript(listen: "prerequest", source: source)
    }

    mutating func setTestScript(_ source: String) {
        setScript(listen: "test", source: source)
    }

    mutating func setScript(listen: String, source: String) {
        var events = event ?? []
        events.removeAll { $0.listen == listen }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            events.append(PMEvent(listen: listen, script: PMEvent.Script(type: "text/javascript", exec: source.components(separatedBy: "\n"))))
        }
        event = events.isEmpty ? nil : events
    }
}

struct CollectionInfo: Codable, Hashable {
    var _postman_id: String?
    var name: String
    var description: RichText?
    var schema: String?
    var version: JSONValue?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._postman_id = try container.decodeIfPresent(String.self, forKey: ._postman_id)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Collection"
        self.description = try container.decodeIfPresent(RichText.self, forKey: .description)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
        self.version = try container.decodeIfPresent(JSONValue.self, forKey: .version)
    }

    init(name: String, id: String = UUID().uuidString) {
        self._postman_id = id
        self.name = name
        self.schema = PostmanSchema.collectionV21
    }

    private enum CodingKeys: String, CodingKey {
        case _postman_id, id, name, description, schema, version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_postman_id, forKey: ._postman_id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description?.content, forKey: .description)
        try container.encodeIfPresent(schema ?? PostmanSchema.collectionV21, forKey: .schema)
        try container.encodeIfPresent(version, forKey: .version)
    }
}

enum PostmanSchema {
    static let collectionV21 = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
    static let collectionV20 = "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"
    static let environment = "https://schema.getpostman.com/json/environment/v1.0.0/environment.json"
}

struct PMCollection: Codable, Identifiable, Hashable {
    var info: CollectionInfo
    var item: [CollectionItem]?
    var auth: Auth?
    var event: [PMEvent]?
    var variable: [KeyValue]?
    var protocolProfileBehavior: [String: JSONValue]?

    init(name: String, items: [CollectionItem] = []) {
        self.info = CollectionInfo(name: name)
        self.item = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var info = try container.decode(CollectionInfo.self, forKey: .info)
        if info._postman_id == nil { info._postman_id = UUID().uuidString }
        self.info = info
        self.item = try container.decodeIfPresent([CollectionItem].self, forKey: .item)
        self.auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
        self.event = try container.decodeIfPresent([PMEvent].self, forKey: .event)
        self.variable = try container.decodeIfPresent([KeyValue].self, forKey: .variable)
        self.protocolProfileBehavior = try container.decodeIfPresent([String: JSONValue].self, forKey: .protocolProfileBehavior)
    }

    private enum CodingKeys: String, CodingKey {
        case info, item, auth, event, variable, protocolProfileBehavior
    }

    var id: String { info._postman_id ?? info.name }
    var items: [CollectionItem] { item ?? [] }
    var preRequestScript: String { event?.first(where: { $0.listen == "prerequest" })?.source ?? "" }
    var testScript: String { event?.first(where: { $0.listen == "test" })?.source ?? "" }

    mutating func setScript(listen: String, source: String) {
        var events = event ?? []
        events.removeAll { $0.listen == listen }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            events.append(PMEvent(listen: listen, script: PMEvent.Script(type: "text/javascript", exec: source.components(separatedBy: "\n"))))
        }
        event = events.isEmpty ? nil : events
    }
}

// MARK: - Environments / presets / library

struct PMEnvironment: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var values: [KeyValue]
    var _postman_variable_scope: String?

    init(id: String = UUID().uuidString, name: String, values: [KeyValue] = []) {
        self.id = id
        self.name = name
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Environment"
        self.values = try container.decodeIfPresent([KeyValue].self, forKey: .values) ?? []
        self._postman_variable_scope = try container.decodeIfPresent(String.self, forKey: ._postman_variable_scope)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, values, _postman_variable_scope
    }

    var pairs: [String: String] {
        var result: [String: String] = [:]
        for row in values where row.isEnabled && !row.key.isEmpty {
            result[row.key] = row.value
        }
        return result
    }
}

struct HeaderPreset: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var header: [KeyValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Preset"
        self.header = try container.decodeIfPresent([KeyValue].self, forKey: .header) ?? []
    }

    init(name: String, header: [KeyValue]) {
        self.id = UUID().uuidString
        self.name = name
        self.header = header
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, header
    }
}

struct Library: Codable {
    var collections: [PMCollection] = []
    var environments: [PMEnvironment] = []
    var globals: [KeyValue] = []
    var headerPresets: [HeaderPreset] = []
    var settings = AppSettings()
    var activeEnvironmentID: String?
    var mockServices: [MockService] = []
    var mockDefaultsSeeded = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.collections = try container.decodeIfPresent([PMCollection].self, forKey: .collections) ?? []
        self.environments = try container.decodeIfPresent([PMEnvironment].self, forKey: .environments) ?? []
        self.globals = try container.decodeIfPresent([KeyValue].self, forKey: .globals) ?? []
        self.headerPresets = try container.decodeIfPresent([HeaderPreset].self, forKey: .headerPresets) ?? []
        self.settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        self.activeEnvironmentID = try container.decodeIfPresent(String.self, forKey: .activeEnvironmentID)
        self.mockServices = try container.decodeIfPresent([MockService].self, forKey: .mockServices) ?? []
        self.mockDefaultsSeeded = try container.decodeIfPresent(Bool.self, forKey: .mockDefaultsSeeded) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case collections, environments, globals, headerPresets, settings, activeEnvironmentID
        case mockServices, mockDefaultsSeeded
    }
}

// A snapshot of the library is handed to the persistence queue after every edit. All stored
// properties are value types, so the copy is independent of the main-actor instance.
extension Library: @unchecked Sendable {}
