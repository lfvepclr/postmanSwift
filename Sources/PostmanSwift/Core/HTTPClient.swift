import Foundation
import Security

struct PreparedRequest {
    var method: String
    var url: URL
    var headers: [KeyValue]
    var body: Data?
    var bodySummary: String = ""
    var displayURL: String { url.absoluteString }
}

struct RequestTimings: Codable, Hashable {
    var dns: Double?
    var connect: Double?
    var tls: Double?
    var request: Double?
    var ttfb: Double?
    var download: Double?
    var total: Double
    var protocolName: String?
    var remoteAddress: String?
}

struct HTTPResult {
    var statusCode: Int
    var statusText: String
    var headers: [KeyValue]
    var body: Data
    var duration: Double
    var finalURL: URL
    var mimeType: String?
    var redirects: [String]
    var usedLegacySocketFallback = false
    /// Set when the body was streamed to disk because it exceeded the in-memory budget.
    var bodyFileURL: URL?
    var byteCount = 0
    var timings: RequestTimings?

    var text: String? { ContentUtilities.decodeText(body, mime: mimeType) }
    var size: Int { bodyFileURL == nil ? body.count : byteCount }
    var isBodyFileBacked: Bool { bodyFileURL != nil }

    /// Reads at most `maxBytes` from the body, whether it lives in memory or on disk.
    func bodyPrefix(maxBytes: Int) -> Data {
        guard let bodyFileURL else { return body.prefix(maxBytes) }
        guard let handle = try? FileHandle(forReadingFrom: bodyFileURL) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }
}

final class HTTPClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let settings: AppSettings
    private let cookieJar: CookieJar?
    private var continuation: CheckedContinuation<HTTPResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startTime = Date()
    private var redirectCount = 0
    private var redirects: [String] = []
    private var originalHost: String?
    private var originalURL = URL(string: "about:blank")!
    private var accumulator: ResponseBodyAccumulator?
    private var partialResponse: HTTPURLResponse?
    private var pendingTimings: RequestTimings?
    private let spillDirectory: URL

    init(settings: AppSettings, cookieJar: CookieJar?, spillDirectory: URL? = nil) {
        self.settings = settings
        self.cookieJar = cookieJar
        self.spillDirectory = spillDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PostmanSwiftResponseCache", isDirectory: true)
    }

    func send(_ prepared: PreparedRequest) async throws -> HTTPResult {
        do {
            return try await sendWithURLSession(prepared)
        } catch {
            guard shouldFallbackToSocket(prepared, error: error) else { throw error }
            var result = try await RawHTTPClient.send(
                prepared,
                settings: settings,
                cookieJar: cookieJar,
                spillDirectory: spillDirectory
            )
            result.usedLegacySocketFallback = true
            return result
        }
    }

    private func shouldFallbackToSocket(_ prepared: PreparedRequest, error: Error) -> Bool {
        guard prepared.url.scheme?.lowercased() == "http", settings.useSocketFallbackForLegacyHTTP else {
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == -1022 { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.code == -1022 {
            return true
        }
        return false
    }

    private func sendWithURLSession(_ prepared: PreparedRequest) async throws -> HTTPResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.startTime = Date()
            self.redirectCount = 0
            self.redirects = []
            self.originalHost = prepared.url.host
            self.originalURL = prepared.url

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            if settings.timeoutSeconds > 0 {
                configuration.timeoutIntervalForRequest = settings.timeoutSeconds
                configuration.timeoutIntervalForResource = settings.timeoutSeconds
            } else {
                configuration.timeoutIntervalForRequest = 300
                configuration.timeoutIntervalForResource = 1800
            }
            if settings.proxyEnabled, !settings.proxyHost.isEmpty {
                configuration.connectionProxyDictionary = [
                    "HTTPEnable": 1,
                    "HTTPProxy": settings.proxyHost,
                    "HTTPPort": settings.proxyPort,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": settings.proxyHost,
                    "HTTPSPort": settings.proxyPort
                ]
            }

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: prepared.url)
            request.httpMethod = prepared.method
            request.httpBody = prepared.body
            for header in prepared.headers where header.isEnabled && !header.key.isEmpty {
                request.setValue(header.value, forHTTPHeaderField: header.key)
            }
            request.setValue(request.value(forHTTPHeaderField: "Accept") ?? "*/*", forHTTPHeaderField: "Accept")
            request.setValue(request.value(forHTTPHeaderField: "User-Agent") ?? "PostmanSwift/1.0", forHTTPHeaderField: "User-Agent")
            if settings.timeoutSeconds > 0 {
                request.timeoutInterval = settings.timeoutSeconds
            }

            let task = session.dataTask(with: request)
            self.partialResponse = nil
            self.pendingTimings = nil
            self.accumulator = ResponseBodyAccumulator(
                threshold: settings.maxInMemoryResponseBytes,
                directory: spillDirectory
            )
            self.task = task
            task.resume()
        }
    }

    // MARK: - URLSession delegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            partialResponse = http
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        accumulator?.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1_000)
        }
        pendingTimings = RequestTimings(
            dns: milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: milliseconds(transaction.connectStartDate, transaction.connectEndDate),
            tls: milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            request: milliseconds(transaction.requestStartDate, transaction.requestEndDate),
            ttfb: milliseconds(transaction.requestEndDate, transaction.responseStartDate),
            download: milliseconds(transaction.responseStartDate, transaction.responseEndDate),
            total: metrics.taskInterval.duration * 1_000,
            protocolName: transaction.networkProtocolName,
            remoteAddress: transaction.remoteAddress
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
            self.task = nil
        }
        if let error {
            accumulator?.discard()
            accumulator = nil
            partialResponse = nil
            resume(throwing: error)
            return
        }
        guard let httpResponse = partialResponse ?? task.response as? HTTPURLResponse else {
            accumulator?.discard()
            accumulator = nil
            partialResponse = nil
            resume(throwing: URLError(.badServerResponse))
            return
        }
        if let jar = cookieJar, let url = httpResponse.url ?? task.currentRequest?.url {
            jar.ingest(response: httpResponse, url: url)
        }
        let headers = httpResponse.allHeaderFields.compactMap { pair -> KeyValue? in
            guard let key = pair.key as? String else { return nil }
            return KeyValue(key: key, value: String(describing: pair.value))
        }.sorted { $0.key.lowercased() < $1.key.lowercased() }

        let (data, fileURL, bytes) = accumulator?.finish() ?? (Data(), nil, 0)
        accumulator = nil
        partialResponse = nil
        let result = HTTPResult(
            statusCode: httpResponse.statusCode,
            statusText: Self.reason(for: httpResponse.statusCode),
            headers: headers,
            body: data,
            duration: Date().timeIntervalSince(self.startTime),
            finalURL: httpResponse.url ?? task.originalRequest?.url ?? self.originalURL,
            mimeType: httpResponse.mimeType,
            redirects: self.redirects,
            bodyFileURL: fileURL,
            byteCount: fileURL == nil ? data.count : bytes,
            timings: pendingTimings
        )
        pendingTimings = nil
        resume(returning: result)
    }

    func cancel() {
        task?.cancel()
    }

    private func resume(returning result: HTTPResult) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    private func resume(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust, !settings.sslVerification,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if method == NSURLAuthenticationMethodClientCertificate,
           let path = settings.clientCertPath,
           let credential = Self.clientCredential(path: path, password: settings.clientCertPassword ?? "") {
            completionHandler(.useCredential, credential)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard settings.followRedirects else {
            completionHandler(nil)
            return
        }
        redirectCount += 1
        redirects.append("\(response.statusCode) → \(request.url?.absoluteString ?? "")")
        guard redirectCount <= settings.maxRedirects else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if [301, 302, 303].contains(response.statusCode),
           let method = request.httpMethod?.uppercased(), method != "GET", method != "HEAD" {
            redirected.httpMethod = "GET"
            redirected.httpBody = nil
            redirected.setValue(nil, forHTTPHeaderField: "Content-Type")
            redirected.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        if let originalHost, request.url?.host?.lowercased() != originalHost.lowercased() {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    private static func clientCredential(path: String, password: String) -> URLCredential? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let entry = array.first,
              let identity = entry[kSecImportItemIdentity as String] else {
            return nil
        }
        return URLCredential(identity: identity as! SecIdentity, certificates: nil, persistence: .forSession)
    }

    static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 418: return "I'm a teapot"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:
            return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        }
    }
}
