import Foundation

struct AppSettings: Codable, Hashable {
    var followRedirects = true
    var maxRedirects = 10
    var timeoutSeconds = 0.0
    var sslVerification = true
    var sendCookies = true
    var proxyEnabled = false
    var proxyHost = ""
    var proxyPort = 8080
    var autoEncodeURL = true
    var theme = "system"
    var useSocketFallbackForLegacyHTTP = true
    var maxResponseDisplayBytes = 8_000_000
    /// Bodies larger than this are streamed to a temp file instead of living in memory.
    var maxInMemoryResponseBytes = 32 * 1_024 * 1_024
    var clientCertPath: String?
    var clientCertPassword: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followRedirects = try c.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? true
        maxRedirects = try c.decodeIfPresent(Int.self, forKey: .maxRedirects) ?? 10
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 0
        sslVerification = try c.decodeIfPresent(Bool.self, forKey: .sslVerification) ?? true
        sendCookies = try c.decodeIfPresent(Bool.self, forKey: .sendCookies) ?? true
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8080
        autoEncodeURL = try c.decodeIfPresent(Bool.self, forKey: .autoEncodeURL) ?? true
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        useSocketFallbackForLegacyHTTP = try c.decodeIfPresent(Bool.self, forKey: .useSocketFallbackForLegacyHTTP) ?? true
        maxResponseDisplayBytes = try c.decodeIfPresent(Int.self, forKey: .maxResponseDisplayBytes) ?? 8_000_000
        maxInMemoryResponseBytes = try c.decodeIfPresent(Int.self, forKey: .maxInMemoryResponseBytes) ?? 32 * 1_024 * 1_024
        clientCertPath = try c.decodeIfPresent(String.self, forKey: .clientCertPath)
        clientCertPassword = try c.decodeIfPresent(String.self, forKey: .clientCertPassword)
    }

    private enum CodingKeys: String, CodingKey {
        case followRedirects, maxRedirects, timeoutSeconds, sslVerification, sendCookies
        case proxyEnabled, proxyHost, proxyPort, autoEncodeURL, theme, maxResponseDisplayBytes
        case maxInMemoryResponseBytes
        case useSocketFallbackForLegacyHTTP
        case clientCertPath, clientCertPassword
    }
}

enum BodyMode: String, CaseIterable, Identifiable, Codable {
    case none
    case formdata
    case urlencoded
    case raw
    case binary
    case graphql

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "none"
        case .formdata: return "form-data"
        case .urlencoded: return "x-www-form-urlencoded"
        case .raw: return "raw"
        case .binary: return "binary"
        case .graphql: return "GraphQL"
        }
    }
}

enum RawLanguage: String, CaseIterable, Identifiable, Codable {
    case json, xml, html, text, javascript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .text: return "Text"
        case .javascript: return "JavaScript"
        }
    }

    var contentType: String {
        switch self {
        case .json: return "application/json"
        case .xml: return "application/xml"
        case .html: return "text/html"
        case .text: return "text/plain"
        case .javascript: return "application/javascript"
        }
    }
}

struct RequestDraft: Hashable, Codable {
    var name: String = "Untitled Request"
    var method: String = "GET"
    var urlRaw: String = ""
    var params: [KeyValue] = []
    var headers: [KeyValue] = []
    var bodyMode: BodyMode = .none
    var rawBody: String = ""
    var rawLanguage: RawLanguage = .json
    var urlencoded: [KeyValue] = []
    var formdata: [KeyValue] = []
    var graphqlQuery: String = ""
    var graphqlVariables: String = ""
    var binaryFilePath: String = ""
    var auth: Auth = .inherit
    var preRequestScript: String = ""
    var testScript: String = ""
    var description: String = ""
    var followRedirects: Bool = true
    var strictSSL: Bool = true

    static func make(from item: CollectionItem) -> RequestDraft {
        var draft = RequestDraft()
        draft.name = item.name
        let request = item.request ?? RequestDef()
        draft.method = (request.method ?? "GET").uppercased()
        draft.urlRaw = request.rawURL
        draft.headers = request.header ?? []
        draft.auth = request.auth ?? .inherit
        draft.preRequestScript = item.preRequestScript
        draft.testScript = item.testScript
        draft.description = item.description?.content ?? ""

        if let body = request.body {
            switch body.mode {
            case "raw":
                draft.bodyMode = .raw
                draft.rawBody = body.raw ?? ""
                if let language = body.options?.raw?.language, let parsed = RawLanguage(rawValue: language) {
                    draft.rawLanguage = parsed
                }
            case "urlencoded":
                draft.bodyMode = .urlencoded
                draft.urlencoded = body.urlencoded ?? []
            case "formdata":
                draft.bodyMode = .formdata
                draft.formdata = body.formdata ?? []
            case "graphql":
                draft.bodyMode = .graphql
                draft.graphqlQuery = body.graphql?.query ?? ""
                if let variables = body.graphql?.variables {
                    draft.graphqlVariables = variables.stringValue ?? variables.debugDescription
                }
            case "file":
                draft.bodyMode = .binary
                if let source = body.file?.src {
                    if case .string(let path) = source {
                        draft.binaryFilePath = path
                    } else if case .array(let values) = source, case .string(let path)? = values.first {
                        draft.binaryFilePath = path
                    }
                }
            default:
                draft.bodyMode = .none
            }
        }

        let query = request.url?.query ?? URLUtilities.parseQuery(from: draft.urlRaw)
        draft.params = query.filter { !$0.key.isEmpty || !$0.value.isEmpty }
        return draft
    }

    func materialize(into item: inout CollectionItem) {
        item.name = name
        var request = item.request ?? RequestDef()
        request.method = method
        request.header = headers.isEmpty ? nil : headers
        request.auth = auth
        request.body = {
            switch bodyMode {
            case .none:
                return nil
            case .raw:
                return RequestBody(
                    mode: "raw",
                    raw: rawBody,
                    options: BodyOptions(raw: RawBodyOptions(language: rawLanguage.rawValue))
                )
            case .urlencoded:
                return RequestBody(mode: "urlencoded", urlencoded: urlencoded)
            case .formdata:
                return RequestBody(mode: "formdata", formdata: formdata)
            case .graphql:
                return RequestBody(
                    mode: "graphql",
                    graphql: GraphQLBody(query: graphqlQuery, variables: .string(graphqlVariables))
                )
            case .binary:
                return RequestBody(mode: "file", file: FileBody(src: nil))
            }
        }()
        request.url = URLDef(raw: urlRaw, query: params.isEmpty ? nil : params)
        request.description = description.isEmpty ? nil : RichText(description)
        item.request = request
        item.setPreRequestScript(preRequestScript)
        item.setTestScript(testScript)
    }

    func asRequestDef() -> RequestDef {
        var item = CollectionItem(name: name, request: RequestDef())
        materialize(into: &item)
        return item.request ?? RequestDef()
    }

    var hasScripts: Bool {
        !preRequestScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !testScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The request as actually sent after variables, auth and cookies were applied.
struct ResolvedRequest: Codable, Hashable {
    var method: String
    var url: String
    var headers: [KeyValue]
    var body: Data?
}

struct HistoryEntry: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var method: String
    var url: String
    var statusCode: Int
    var duration: Double
    var responseSize: Int
    var collectionID: String?
    var collectionName: String?
    var requestName: String?
    var request: RequestDef
    var responseHeaders: [KeyValue]
    var responseBody: Data?
    var responseText: String?
    var mimeType: String?
    var itemID: String?
    var resolvedRequest: ResolvedRequest?
    var timings: RequestTimings?
    /// Persisted path for responses that were streamed to disk.
    var responseBodyPath: String?
    /// Transient: file that should be copied into history storage when this row is inserted.
    var responseBodySourceURL: URL?
    /// True when only the summary columns were read; request and response bodies load on demand.
    var isSummary = false
}

/// Pre-formatted history row fields. Building these once per refresh keeps `body` from
/// allocating a relative-date formatter for every row on every render.
struct HistoryRowDisplay: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let method: String
    let url: String
    let statusCode: Int
    let timeText: String
    let requestName: String?
    let sizeText: String
    let durationText: String
}

struct TestResult: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var passed: Bool
    var errorMessage: String?
}

struct ConsoleEntry: Identifiable, Hashable {
    enum Kind: String {
        case request = "Request"
        case response = "Response"
        case script = "Script"
        case error = "Error"
    }

    var id = UUID()
    var timestamp = Date()
    var kind: Kind
    var title: String
    var detail: String
}
