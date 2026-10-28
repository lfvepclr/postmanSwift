import Foundation

enum OpenAPIImporter {
    static func importDocument(_ document: [String: Any]) throws -> ImportResult {
        if document["openapi"] != nil {
            return try importOpenAPI3(document)
        }
        if document["swagger"] != nil {
            return try importSwagger2(document)
        }
        throw ImportError.unsupported("OpenAPI document")
    }

    private static func importOpenAPI3(_ document: [String: Any]) throws -> ImportResult {
        let info = document["info"] as? [String: Any] ?? [:]
        let title = info["title"] as? String ?? "Imported API"
        let servers = document["servers"] as? [[String: Any]] ?? []
        let baseURL = servers.first?["url"] as? String ?? ""
        let paths = document["paths"] as? [String: Any] ?? [:]
        var result = ImportResult()

        var items: [CollectionItem] = []
        var warnings: [String] = []
        for (path, rawPathItem) in paths.sorted(by: { $0.key < $1.key }) {
            guard let pathItem = rawPathItem as? [String: Any] else { continue }
            for method in ["get", "post", "put", "patch", "delete", "head", "options"] {
                guard let operation = pathItem[method] as? [String: Any] else { continue }
                var draft = RequestDraft()
                draft.method = method.uppercased()
                draft.name = operation["summary"] as? String ?? operation["operationId"] as? String ?? "\(method.uppercased()) \(path)"
                draft.urlRaw = baseURL + path
                draft.params = URLUtilities.parseQuery(from: draft.urlRaw)

                if let parameters = operation["parameters"] as? [[String: Any]] {
                    applyParameters(parameters, to: &draft, path: path)
                }
                if let parameters = pathItem["parameters"] as? [[String: Any]] {
                    applyParameters(parameters, to: &draft, path: path)
                }
                if let requestBody = operation["requestBody"] as? [String: Any],
                   let content = requestBody["content"] as? [String: Any] {
                    applyOpenAPI3Body(content, to: &draft)
                }
                if operation["security"] != nil {
                    warnings.append("Security requirements for \(draft.method) \(path) were imported without credentials.")
                }
                var item = CollectionItem(name: draft.name, request: RequestDef())
                draft.materialize(into: &item)
                items.append(item)
            }
        }
        result.collections = [PMCollection(name: title, items: items)]
        result.warnings = warnings
        return result
    }

    private static func applyParameters(_ parameters: [[String: Any]], to draft: inout RequestDraft, path: String) {
        for parameter in parameters {
            guard let name = parameter["name"] as? String, let location = parameter["in"] as? String else { continue }
            let example = (parameter["example"] as? String)
                ?? ((parameter["schema"] as? [String: Any])?["example"] as? String)
                ?? ""
            switch location {
            case "query":
                draft.params.append(KeyValue(key: name, value: example))
            case "header":
                draft.headers.append(KeyValue(key: name, value: example))
            case "path":
                if !example.isEmpty {
                    draft.urlRaw = draft.urlRaw.replacingOccurrences(of: "{\(name)}", with: example)
                }
            default:
                break
            }
        }
    }

    private static func applyOpenAPI3Body(_ content: [String: Any], to draft: inout RequestDraft) {
        if let json = content["application/json"] as? [String: Any] {
            if let example = json["example"], let text = jsonText(example) {
                draft.bodyMode = .raw
                draft.rawLanguage = .json
                draft.rawBody = text
            } else if let schema = json["schema"] as? [String: Any], let sample = sampleValue(schema), let text = jsonText(sample) {
                draft.bodyMode = .raw
                draft.rawLanguage = .json
                draft.rawBody = text
            }
        } else if let form = content["application/x-www-form-urlencoded"] as? [String: Any],
                  let schema = form["schema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] {
            draft.bodyMode = .urlencoded
            draft.urlencoded = properties.keys.sorted().map { KeyValue(key: $0, value: "") }
        } else if let multipart = content["multipart/form-data"] as? [String: Any],
                  let schema = multipart["schema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] {
            draft.bodyMode = .formdata
            draft.formdata = properties.keys.sorted().map { key in
                let property = properties[key] as? [String: Any] ?? [:]
                if (property["type"] as? String) == "string", (property["format"] as? String) == "binary" {
                    return KeyValue(key: key, value: "").withType("file")
                }
                return KeyValue(key: key, value: "")
            }
        }
    }

    private static func importSwagger2(_ document: [String: Any]) throws -> ImportResult {
        let info = document["info"] as? [String: Any] ?? [:]
        let title = info["title"] as? String ?? "Imported API"
        let host = document["host"] as? String ?? ""
        let basePath = document["basePath"] as? String ?? ""
        let schemes = document["schemes"] as? [String] ?? []
        let baseURL = host.isEmpty ? basePath : "\(schemes.first ?? "https")://\(host)\(basePath)"
        let paths = document["paths"] as? [String: Any] ?? [:]
        var items: [CollectionItem] = []
        var warnings: [String] = []

        for (path, rawPathItem) in paths.sorted(by: { $0.key < $1.key }) {
            guard let pathItem = rawPathItem as? [String: Any] else { continue }
            for method in ["get", "post", "put", "patch", "delete", "head", "options"] {
                guard let operation = pathItem[method] as? [String: Any] else { continue }
                var draft = RequestDraft()
                draft.method = method.uppercased()
                draft.name = operation["summary"] as? String ?? operation["operationId"] as? String ?? "\(method.uppercased()) \(path)"
                draft.urlRaw = baseURL + path
                let parameters = (pathItem["parameters"] as? [[String: Any]] ?? []) + (operation["parameters"] as? [[String: Any]] ?? [])
                applyParameters(parameters, to: &draft, path: path)
                if let bodyParameters = parameters.filter({ ($0["in"] as? String) == "body" }).first,
                   let schema = bodyParameters["schema"] as? [String: Any],
                   let sample = sampleValue(schema),
                   let text = jsonText(sample) {
                    draft.bodyMode = .raw
                    draft.rawLanguage = .json
                    draft.rawBody = text
                }
                if operation["security"] != nil {
                    warnings.append("Security requirements for \(draft.method) \(path) were imported without credentials.")
                }
                var item = CollectionItem(name: draft.name, request: RequestDef())
                draft.materialize(into: &item)
                items.append(item)
            }
        }
        return ImportResult(collections: [PMCollection(name: title, items: items)], warnings: warnings)
    }

    private static func jsonText(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sampleValue(_ schema: [String: Any]) -> Any? {
        if let example = schema["example"] { return example }
        if let defaultValue = schema["default"] { return defaultValue }
        switch schema["type"] as? String {
        case "object":
            let properties = schema["properties"] as? [String: Any] ?? [:]
            return properties.reduce(into: [String: Any]()) { result, pair in
                if let value = sampleValue(pair.value as? [String: Any] ?? [:]) {
                    result[pair.key] = value
                }
            }
        case "array":
            if let item = schema["items"] as? [String: Any], let value = sampleValue(item) {
                return [value]
            }
            return []
        case "integer", "number":
            return 0
        case "boolean":
            return false
        case "string":
            return ""
        default:
            return nil
        }
    }
}

private extension KeyValue {
    func withType(_ type: String) -> KeyValue {
        var copy = self
        copy.type = type
        return copy
    }
}
