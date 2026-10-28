import Foundation

struct ImportResult {
    var collections: [PMCollection] = []
    var environments: [PMEnvironment] = []
    var globals: [KeyValue] = []
    var warnings: [String] = []
}

enum ImportError: LocalizedError {
    case unreadable
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The selected file could not be read as text or JSON."
        case .unsupported(let detail): return "Unsupported import format: \(detail)"
        case .malformed(let detail): return "Malformed import data: \(detail)"
        }
    }
}

enum ImportExport {
    static func decode(data: Data, filename: String) throws -> ImportResult {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("curl ") || trimmed.lowercased().hasPrefix("curl\n") {
            if var draft = CurlParser.parse(trimmed) {
                draft.name = filename.isEmpty ? "Imported from cURL" : (filename as NSString).deletingPathExtension
                var item = CollectionItem(name: draft.name, request: RequestDef())
                draft.materialize(into: &item)
                let collection = PMCollection(name: "Imported cURL", items: [item])
                return ImportResult(collections: [collection])
            }
            throw ImportError.malformed("cURL command")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ImportError.unreadable
        }
        return try decodeJSON(object)
    }

    private static func decodeJSON(_ object: Any) throws -> ImportResult {
        if let array = object as? [Any] {
            var result = ImportResult()
            for element in array {
                if let child = try? decodeJSON(element) {
                    result.collections.append(contentsOf: child.collections)
                    result.environments.append(contentsOf: child.environments)
                    result.globals.append(contentsOf: child.globals)
                    result.warnings.append(contentsOf: child.warnings)
                }
            }
            guard !result.collections.isEmpty || !result.environments.isEmpty else {
                throw ImportError.unsupported("JSON array without collections")
            }
            return result
        }
        guard let dictionary = object as? [String: Any] else {
            throw ImportError.unsupported("JSON value")
        }
        if dictionary["info"] != nil, dictionary["item"] != nil {
            return ImportResult(collections: [try decodeCollection(dictionary)])
        }
        if dictionary["collections"] != nil || dictionary["environments"] != nil {
            return try decodeBackup(dictionary)
        }
        if dictionary["values"] != nil, dictionary["name"] != nil {
            return try decodeEnvironment(dictionary)
        }
        if dictionary["swagger"] != nil || dictionary["openapi"] != nil {
            return try OpenAPIImporter.importDocument(dictionary)
        }
        throw ImportError.unsupported("unrecognized JSON document")
    }

    private static func decodeCollection(_ dictionary: [String: Any]) throws -> PMCollection {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        var collection = try JSONDecoder().decode(PMCollection.self, from: data)
        if collection.info.schema == nil {
            collection.info.schema = PostmanSchema.collectionV21
        }
        return collection
    }

    private static func decodeEnvironment(_ dictionary: [String: Any]) throws -> ImportResult {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let environment = try JSONDecoder().decode(PMEnvironment.self, from: data)
        if environment._postman_variable_scope == "globals" {
            return ImportResult(globals: environment.values)
        }
        return ImportResult(environments: [environment])
    }

    private static func decodeBackup(_ dictionary: [String: Any]) throws -> ImportResult {
        var result = ImportResult()
        if let collections = dictionary["collections"] as? [[String: Any]] {
            for collection in collections {
                if let decoded = try? decodeCollection(collection) {
                    result.collections.append(decoded)
                } else {
                    result.warnings.append("Skipped one collection that was not in v2.1 format.")
                }
            }
        }
        if let environments = dictionary["environments"] as? [[String: Any]] {
            for environment in environments {
                if let data = try? JSONSerialization.data(withJSONObject: environment),
                   let decoded = try? JSONDecoder().decode(PMEnvironment.self, from: data) {
                    result.environments.append(decoded)
                }
            }
        }
        if let globals = dictionary["globals"] as? [[String: Any]] {
            result.globals = globals.compactMap { row in
                guard let key = row["key"] as? String else { return nil }
                return KeyValue(key: key, value: row["value"] as? String ?? "", disabled: row["disabled"] as? Bool ?? false)
            }
        }
        if result.collections.isEmpty && result.environments.isEmpty && result.globals.isEmpty {
            throw ImportError.unsupported("empty backup")
        }
        return result
    }

    static func encodeCollection(_ collection: PMCollection) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(collection)
    }

    static func encodeEnvironment(_ environment: PMEnvironment) throws -> Data {
        var copy = environment
        copy._postman_variable_scope = "environment"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    static func encodeGlobals(_ globals: [KeyValue]) throws -> Data {
        let environment = PMEnvironment(id: UUID().uuidString, name: "Globals", values: globals)
        var copy = environment
        copy._postman_variable_scope = "globals"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    static func encodeBackup(_ library: Library) throws -> Data {
        let payload: [String: Any] = [
            "version": 1,
            "collections": library.collections,
            "environments": library.environments,
            "headerPresets": library.headerPresets,
            "globals": library.globals
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let collectionsData = try encoder.encode(library.collections)
        let environmentsData = try encoder.encode(library.environments)
        let presetsData = try encoder.encode(library.headerPresets)
        let globalsData = try encoder.encode(library.globals)
        let collectionsObject = try JSONSerialization.jsonObject(with: collectionsData)
        let environmentsObject = try JSONSerialization.jsonObject(with: environmentsData)
        let presetsObject = try JSONSerialization.jsonObject(with: presetsData)
        let globalsObject = try JSONSerialization.jsonObject(with: globalsData)
        let root: [String: Any] = [
            "version": 1,
            "collections": collectionsObject,
            "environments": environmentsObject,
            "headerPresets": presetsObject,
            "globals": globalsObject
        ]
        _ = payload
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}

enum CurlParser {
    static func parse(_ command: String) -> RequestDraft? {
        let cleaned = command
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(cleaned)
        guard tokens.first?.lowercased() == "curl" else { return nil }

        var draft = RequestDraft()
        var method: String?
        var dataParts: [String] = []
        var formRows: [KeyValue] = []
        var headers: [KeyValue] = []
        var url = ""
        var useGet = false
        var index = 1

        func next() -> String? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        while let token = next() {
            switch token {
            case "-X", "--request":
                method = next()?.uppercased()
            case "-H", "--header":
                if let header = next(), let separator = header.firstIndex(of: ":") {
                    let key = String(header[..<separator]).trimmingCharacters(in: .whitespaces)
                    let value = String(header[header.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    headers.append(KeyValue(key: key, value: value))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode":
                if let value = next() { dataParts.append(value) }
            case "-F", "--form":
                if let value = next() {
                    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        var row = KeyValue(key: parts[0], value: parts[1])
                        if parts[1].hasPrefix("@") {
                            row.type = "file"
                            row.src = .string(String(parts[1].dropFirst()))
                            row.value = ""
                        }
                        formRows.append(row)
                    }
                }
            case "-u", "--user":
                if let credentials = next() {
                    let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
                    var auth = Auth(type: "basic")
                    auth.setValue(parts.first ?? "", for: "username")
                    auth.setValue(parts.count > 1 ? parts[1] : "", for: "password")
                    draft.auth = auth
                }
            case "-b", "--cookie":
                if let cookie = next() {
                    headers.append(KeyValue(key: "Cookie", value: cookie))
                }
            case "-A", "--user-agent":
                if let agent = next() {
                    headers.append(KeyValue(key: "User-Agent", value: agent))
                }
            case "-G", "--get":
                useGet = true
            case "--url":
                if let value = next() { url = value }
            case "-k", "--insecure", "-L", "--location", "--compressed", "-s", "--silent", "-i", "--include", "-v", "--verbose":
                continue
            default:
                if token.hasPrefix("-") {
                    continue
                }
                if url.isEmpty {
                    url = token
                }
            }
        }

        guard !url.isEmpty else { return nil }
        draft.method = method ?? (dataParts.isEmpty && formRows.isEmpty ? "GET" : "POST")
        if useGet {
            draft.method = "GET"
            let combined = dataParts.joined(separator: "&")
            url += (url.contains("?") ? "&" : "?") + combined
            dataParts = []
        }
        draft.urlRaw = url
        draft.headers = headers
        draft.params = URLUtilities.parseQuery(from: url).filter { !$0.key.isEmpty || !$0.value.isEmpty }

        if !formRows.isEmpty {
            draft.bodyMode = .formdata
            draft.formdata = formRows
        } else if !dataParts.isEmpty {
            let body = dataParts.joined(separator: "&")
            draft.bodyMode = .raw
            draft.rawBody = body
            let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
            if contentType.contains("json") || body.trimmingCharacters(in: .whitespaces).hasPrefix("{") || body.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                draft.rawLanguage = .json
            } else if contentType.contains("xml") {
                draft.rawLanguage = .xml
            } else if contentType.contains("x-www-form-urlencoded") {
                draft.bodyMode = .urlencoded
                draft.urlencoded = body.split(separator: "&").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return KeyValue(key: (parts.first ?? "").removingPercentEncoding ?? parts.first ?? "",
                                    value: parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : "")
                }
                draft.rawBody = ""
            } else {
                draft.rawLanguage = .text
            }
        } else {
            draft.bodyMode = .none
        }
        if draft.name == "Untitled Request" {
            draft.name = url
        }
        return draft
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
