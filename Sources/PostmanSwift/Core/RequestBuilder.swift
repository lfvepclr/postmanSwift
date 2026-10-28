import Foundation

enum RequestBuildError: LocalizedError {
    case invalidURL(String)
    case emptyURL
    case invalidBody(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid URL: \(value)"
        case .emptyURL: return "Enter a request URL first."
        case .invalidBody(let message): return "Invalid request body: \(message)"
        }
    }
}

enum RequestBuilder {
    static func build(
        draft: RequestDraft,
        context: VariableContext,
        settings: AppSettings,
        cookies: CookieJar?,
        auth: Auth? = nil
    ) throws -> PreparedRequest {
        let raw = draft.urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw RequestBuildError.emptyURL }

        let base = context.resolve(URLUtilities.splitRaw(raw).base)
        var params = draft.params.filter(\.isEnabled)
        if params.isEmpty, let query = URLUtilities.splitRaw(raw).query, !query.isEmpty {
            params = URLUtilities.parseQuery(from: raw)
        }
        var resolvedQuery: [KeyValue] = params.map { row in
            KeyValue(key: context.resolve(row.key), value: context.resolve(row.value))
        }
        var urlString = base
        if !resolvedQuery.isEmpty {
            urlString += "?" + resolvedQuery
                .filter { !($0.key.isEmpty && $0.value.isEmpty) }
                .map { "\(URLUtilities.encodeQueryComponent($0.key))=\(URLUtilities.encodeQueryComponent($0.value))" }
                .joined(separator: "&")
        }

        var headers = draft.headers.filter(\.isEnabled).map { $0.resolved(context) }
        let body = BodyBuilder.build(
            mode: draft.bodyMode,
            raw: draft.rawBody,
            language: draft.rawLanguage,
            urlencoded: draft.urlencoded,
            formdata: draft.formdata,
            graphqlQuery: draft.graphqlQuery,
            graphqlVariables: draft.graphqlVariables,
            binaryPath: draft.binaryFilePath,
            context: context
        )

        if let contentType = body.contentType, headerValue("Content-Type", in: headers) == nil {
            headers.append(KeyValue(key: "Content-Type", value: contentType))
        }

        let auth = auth ?? draft.auth
        let provisionalURL = try makeURL(urlString)
        let contentType = headerValue("Content-Type", in: headers)
        var application: AuthApplication
        do {
            application = try AuthBuilder.apply(
                auth: auth,
                method: draft.method,
                url: provisionalURL,
                body: body.data,
                contentType: contentType,
                context: context
            )
        } catch {
            throw error
        }

        for header in application.headers {
            setHeader(header.key, header.value, in: &headers)
        }

        var finalURL = application.url
        if !application.queryItems.isEmpty {
            finalURL = try append(query: application.queryItems, to: finalURL, context: context)
        }
        if application.url != provisionalURL && application.queryItems.isEmpty {
            finalURL = application.url
        }

        if settings.sendCookies, let cookies, let cookieHeader = cookies.headerValue(for: finalURL),
           headerValue("Cookie", in: headers) == nil {
            headers.append(KeyValue(key: "Cookie", value: cookieHeader))
        }

        var method = draft.method.uppercased()
        var bodyData = body.data
        if method == "GET" || method == "HEAD" {
            bodyData = nil
        }
        headers.removeAll { $0.key.lowercased() == "content-length" }

        return PreparedRequest(
            method: method,
            url: finalURL,
            headers: headers,
            body: bodyData,
            bodySummary: body.summary
        )
    }

    static func build(
        requestDef: RequestDef,
        item: CollectionItem,
        context: VariableContext,
        settings: AppSettings,
        cookies: CookieJar?,
        auth: Auth?
    ) throws -> PreparedRequest {
        let draft = RequestDraft.make(from: item)
        return try build(draft: draft, context: context, settings: settings, cookies: cookies, auth: auth)
    }

    private static func makeURL(_ raw: String) throws -> URL {
        let normalized = URLUtilities.normalize(raw)
        if let url = URL(string: normalized) { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "{}[]|\\^`")
        if let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: encoded) {
            return url
        }
        throw RequestBuildError.invalidURL(raw)
    }

    private static func append(query items: [KeyValue], to url: URL, context: VariableContext) throws -> URL {
        let suffix = items.filter { !$0.key.isEmpty }.map {
            "\(URLUtilities.encodeQueryComponent(context.resolve($0.key)))=\(URLUtilities.encodeQueryComponent(context.resolve($0.value)))"
        }.joined(separator: "&")
        guard !suffix.isEmpty else { return url }
        let separator = url.absoluteString.contains("?") ? "&" : "?"
        guard let combined = URL(string: url.absoluteString + separator + suffix) else {
            throw RequestBuildError.invalidURL(url.absoluteString)
        }
        return combined
    }

    static func headerValue(_ name: String, in headers: [KeyValue]) -> String? {
        headers.first { $0.isEnabled && $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func setHeader(_ name: String, _ value: String, in headers: inout [KeyValue]) {
        if let index = headers.firstIndex(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[index].value = value
            headers[index].disabled = false
        } else {
            headers.append(KeyValue(key: name, value: value))
        }
    }
}
