import Foundation
import UniformTypeIdentifiers

struct BuiltBody {
    var data: Data?
    var contentType: String?
    var summary: String = ""
}

enum BodyBuilder {
    static func build(
        mode: BodyMode,
        raw: String,
        language: RawLanguage,
        urlencoded: [KeyValue],
        formdata: [KeyValue],
        graphqlQuery: String,
        graphqlVariables: String,
        binaryPath: String = "",
        context: VariableContext
    ) -> BuiltBody {
        switch mode {
        case .none:
            return BuiltBody(data: nil, contentType: nil)

        case .raw:
            let text = context.resolve(raw)
            return BuiltBody(data: text.data(using: .utf8), contentType: language.contentType, summary: text)

        case .urlencoded:
            let pairs = urlencoded.filter(\.isEnabled).map { row in
                let key = context.resolve(row.key)
                let value = context.resolve(row.value)
                return "\(URLUtilities.encodeQueryComponent(key))=\(URLUtilities.encodeQueryComponent(value))"
            }
            let text = pairs.joined(separator: "&")
            return BuiltBody(data: text.data(using: .utf8), contentType: "application/x-www-form-urlencoded", summary: text)

        case .formdata:
            let boundary = "----PostmanSwiftBoundary\(UUID().uuidString)"
            var data = Data()
            for row in formdata where row.isEnabled && !row.key.isEmpty {
                let key = context.resolve(row.key)
                data.append(Data("--\(boundary)\r\n".utf8))
                if row.isFile {
                    let path = filePath(from: row.src).map { context.resolve($0) } ?? ""
                    let filename = (path as NSString).lastPathComponent
                    let mime = mimeType(for: path)
                    data.append(Data("Content-Disposition: form-data; name=\"\(escape(key))\"; filename=\"\(escape(filename))\"\r\n".utf8))
                    data.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
                    if let contents = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        data.append(contents)
                    }
                    data.append(Data("\r\n".utf8))
                } else {
                    let value = context.resolve(row.value)
                    data.append(Data("Content-Disposition: form-data; name=\"\(escape(key))\"\r\n\r\n".utf8))
                    data.append(Data(value.utf8))
                    data.append(Data("\r\n".utf8))
                }
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            return BuiltBody(data: data, contentType: "multipart/form-data; boundary=\(boundary)", summary: "multipart/form-data")

        case .graphql:
            let query = context.resolve(graphqlQuery)
            var variablesObject: Any = [String: Any]()
            let resolvedVariables = context.resolve(graphqlVariables)
            if let data = resolvedVariables.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                variablesObject = parsed
            }
            let payload: [String: Any] = ["query": query, "variables": variablesObject]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return BuiltBody(data: data, contentType: "application/json", summary: query)

        case .binary:
            let path = context.resolve(binaryPath)
            guard !path.isEmpty else {
                return BuiltBody(data: nil, contentType: "application/octet-stream", summary: "binary")
            }
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            return BuiltBody(data: data, contentType: mimeType(for: path), summary: (path as NSString).lastPathComponent)
        }
    }

    private static func filePath(from source: JSONValue?) -> String? {
        guard let source else { return nil }
        if case .string(let path) = source { return path }
        if case .array(let values) = source, case .string(let path)? = values.first { return path }
        return nil
    }

    private static func mimeType(for path: String) -> String {
        let extensionName = (path as NSString).pathExtension
        return UTType(filenameExtension: extensionName)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
