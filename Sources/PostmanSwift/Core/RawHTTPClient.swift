import Foundation
import Darwin

/// Plaintext HTTP/1.1 transport built on BSD sockets.
///
/// macOS 26 enforces App Transport Security on URLSession and Network.framework and
/// no longer honors `NSAllowsArbitraryLoads`, which would otherwise make ordinary
/// `http://` API endpoints unreachable. Socket-level HTTP is not part of the URL
/// Loading System, so this path preserves Postman-compatible cleartext requests.
enum RawHTTPClient {
    private struct RawResponse {
        var statusCode: Int
        var headers: [KeyValue]
        var setCookies: [String]
        var body: Data
        var mimeType: String?
        var timings: RequestTimings?
    }

    static func send(
        _ prepared: PreparedRequest,
        settings: AppSettings,
        cookieJar: CookieJar?,
        spillDirectory: URL? = nil
    ) async throws -> HTTPResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try sendSync(
                        prepared,
                        settings: settings,
                        cookieJar: cookieJar,
                        spillDirectory: spillDirectory
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sendSync(
        _ prepared: PreparedRequest,
        settings: AppSettings,
        cookieJar: CookieJar?,
        spillDirectory: URL?
    ) throws -> HTTPResult {
        let start = Date()
        var request = prepared
        var redirects: [String] = []
        let maxRedirects = settings.followRedirects ? max(0, settings.maxRedirects) : 0

        if settings.sendCookies, let cookieJar, let cookie = cookieJar.headerValue(for: request.url),
           !request.headers.contains(where: { $0.key.lowercased() == "cookie" }) {
            request.headers.append(KeyValue(key: "Cookie", value: cookie))
        }

        while true {
            let response = try perform(request, settings: settings)
            if let cookieJar {
                cookieJar.ingest(setCookieHeaders: response.setCookies, url: request.url)
            }

            if let location = response.headers.first(where: { $0.key.lowercased() == "location" })?.value,
               [301, 302, 303, 307, 308].contains(response.statusCode),
               settings.followRedirects,
               redirects.count < maxRedirects,
               let nextURL = URL(string: location, relativeTo: request.url)?.absoluteURL {
                redirects.append("\(response.statusCode) → \(nextURL.absoluteString)")
                var next = request
                next.url = nextURL
                if [301, 302, 303].contains(response.statusCode),
                   next.method != "GET", next.method != "HEAD" {
                    next.method = "GET"
                    next.body = nil
                    next.bodySummary = ""
                    next.headers.removeAll {
                        ["content-type", "content-length", "transfer-encoding"].contains($0.key.lowercased())
                    }
                }
                if nextURL.host?.lowercased() != request.url.host?.lowercased() {
                    next.headers.removeAll { $0.key.lowercased() == "authorization" }
                }
                next.headers.removeAll { $0.key.lowercased() == "cookie" }
                if settings.sendCookies, let cookieJar, let cookie = cookieJar.headerValue(for: nextURL) {
                    next.headers.append(KeyValue(key: "Cookie", value: cookie))
                }
                request = next
                continue
            }

            var result = HTTPResult(
                statusCode: response.statusCode,
                statusText: HTTPClient.reason(for: response.statusCode),
                headers: response.headers,
                body: response.body,
                duration: Date().timeIntervalSince(start),
                finalURL: request.url,
                mimeType: response.mimeType,
                redirects: redirects,
                timings: response.timings
            )
            // The socket reader buffers the exchange in memory; move oversized bodies to disk so
            // they do not stay resident afterwards.
            if response.body.count > settings.maxInMemoryResponseBytes {
                let directory = spillDirectory
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("PostmanSwiftResponseCache", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("http-\(UUID().uuidString).bin")
                if (try? response.body.write(to: url, options: .atomic)) != nil {
                    result.byteCount = response.body.count
                    result.bodyFileURL = url
                    result.body = Data()
                }
            }
            return result
        }
    }

    // MARK: - One HTTP exchange

    private static func perform(_ request: PreparedRequest, settings: AppSettings) throws -> RawResponse {
        let url = request.url
        guard let host = url.host, !host.isEmpty else {
            throw RawHTTPError.malformed("Request URL has no host")
        }
        let scheme = url.scheme?.lowercased() ?? "http"
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let timeout = settings.timeoutSeconds > 0 ? settings.timeoutSeconds : 60

        let explicitProxy = settings.proxyEnabled && !settings.proxyHost.isEmpty
        let systemProxy = explicitProxy ? nil : SystemProxy.httpProxy()
        let proxyHost: String? = explicitProxy ? settings.proxyHost : systemProxy?.host
        let proxyPort: UInt16? = explicitProxy ? (UInt16(settings.proxyPort) ?? 8080) : systemProxy?.port
        let connectHost = proxyHost ?? host
        guard let defaultPort = UInt16(exactly: port) else {
            throw RawHTTPError.malformed("Invalid port")
        }
        let connectPort = proxyPort ?? defaultPort

        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?" + $0 } ?? ""
        let originTarget = path + query
        let target = proxyHost == nil ? originTarget : url.absoluteString
        let method = request.method.uppercased()

        var headerLines: [String] = []
        headerLines.append("Host: \(host)" + (port != 80 ? ":\(port)" : ""))
        var hasAcceptEncoding = false
        var hasUserAgent = false
        for header in request.headers where header.isEnabled && !header.key.isEmpty {
            let lower = header.key.lowercased()
            if ["host", "content-length", "connection", "proxy-connection"].contains(lower) { continue }
            if lower == "accept-encoding" { hasAcceptEncoding = true }
            if lower == "user-agent" { hasUserAgent = true }
            headerLines.append("\(header.key): \(header.value)")
        }
        if !hasAcceptEncoding { headerLines.append("Accept-Encoding: identity") }
        if !hasUserAgent { headerLines.append("User-Agent: PostmanSwift/1.0") }
        headerLines.append("Connection: close")
        if let body = request.body {
            headerLines.append("Content-Length: \(body.count)")
        }

        var payload = Data("\(method) \(target) HTTP/1.1\r\n".utf8)
        for line in headerLines {
            payload.append(Data((line + "\r\n").utf8))
        }
        payload.append(Data("\r\n".utf8))
        if let body = request.body { payload.append(body) }

        let exchangeStart = Date()
        let fd = try openSocket(host: connectHost, port: connectPort, timeout: timeout)
        let connectedAt = Date()
        defer { Darwin.close(fd) }
        configureSocket(fd, timeout: timeout)
        try writeAll(fd, payload)
        let requestSentAt = Date()

        var reader = SocketReader(fd: fd)
        var head = try reader.readHead()
        let firstByteAt = Date()
        while (100...199).contains(head.statusCode) {
            if let length = headerValue("content-length", in: head.headers), let size = Int(length) {
                _ = try reader.readExactly(size)
            }
            head = try reader.readHead()
        }

        let mime = headerValue("content-type", in: head.headers)?.split(separator: ";").first.map(String.init)
        let body: Data
        if method == "HEAD" || head.statusCode == 204 || head.statusCode == 304 {
            body = Data()
        } else if headerValue("transfer-encoding", in: head.headers)?.lowercased().contains("chunked") == true {
            body = try reader.readChunked(prefix: head.bodyPrefix)
        } else if let lengthText = headerValue("content-length", in: head.headers),
                  let length = Int(lengthText) {
            var data = Data(head.bodyPrefix)
            if data.count < length {
                data.append(try reader.readExactly(length - data.count))
            }
            body = data.prefix(length)
        } else {
            var data = Data(head.bodyPrefix)
            data.append(try reader.readUntilEOF())
            body = data
        }

        let completedAt = Date()
        let timings = RequestTimings(
            dns: nil,
            connect: connectedAt.timeIntervalSince(exchangeStart) * 1_000,
            tls: nil,
            request: requestSentAt.timeIntervalSince(connectedAt) * 1_000,
            ttfb: firstByteAt.timeIntervalSince(requestSentAt) * 1_000,
            download: completedAt.timeIntervalSince(firstByteAt) * 1_000,
            total: completedAt.timeIntervalSince(exchangeStart) * 1_000,
            protocolName: "HTTP/1.1",
            remoteAddress: "\(connectHost):\(connectPort)"
        )
        return RawResponse(
            statusCode: head.statusCode,
            headers: head.headers,
            setCookies: head.setCookies,
            body: body,
            mimeType: mime,
            timings: timings
        )
    }

    private static func headerValue(_ name: String, in headers: [KeyValue]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Socket helpers

    private static func openSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw RawHTTPError.resolution("Could not resolve \(host)")
        }
        defer { freeaddrinfo(first) }

        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if rc == 0 {
                    fcntl(fd, F_SETFL, flags)
                    return fd
                }
                if errno == EINPROGRESS {
                    var writeSet = fd_set()
                    zeroSet(&writeSet)
                    insert(fd: fd, into: &writeSet)
                    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    let selected = select(fd + 1, nil, &writeSet, nil, &tv)
                    if selected > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                        if socketError == 0 {
                            fcntl(fd, F_SETFL, flags)
                            return fd
                        }
                    }
                }
                Darwin.close(fd)
            }
            pointer = info.pointee.ai_next
        }
        throw RawHTTPError.connect("Could not connect to \(host):\(port)")
    }

    private static func configureSocket(_ fd: Int32, timeout: TimeInterval) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func zeroSet(_ set: inout fd_set) {
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                for index in 0..<32 { bits[index] = 0 }
            }
        }
    }

    private static func insert(fd: Int32, into set: inout fd_set) {
        let index = Int(fd) / 32
        let bit = Int32(1) << Int32(Int(fd) % 32)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[index] |= bit
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written > 0 {
                    offset += written
                } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                    continue
                } else {
                    throw RawHTTPError.connect("Connection closed while sending")
                }
            }
        }
    }
}

enum RawHTTPError: LocalizedError {
    case resolution(String)
    case connect(String)
    case timeout
    case closed
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .resolution(let detail): return "DNS resolution failed: \(detail)"
        case .connect(let detail): return "Connection failed: \(detail)"
        case .timeout: return "The request timed out."
        case .closed: return "The server closed the connection before the response completed."
        case .malformed(let detail): return "Malformed HTTP response: \(detail)"
        }
    }
}

private struct RawHead {
    var statusCode: Int
    var headers: [KeyValue]
    var setCookies: [String]
    var bodyPrefix: Data
}

private struct SocketReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    mutating func readHead() throws -> RawHead {
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<range.lowerBound]
                let rest = Data(buffer[range.upperBound...])
                buffer = Data()
                guard let text = String(data: headerData, encoding: .isoLatin1) else {
                    throw RawHTTPError.malformed("Non-ASCII status line")
                }
                let lines = text.components(separatedBy: "\r\n")
                guard let statusLine = lines.first else {
                    throw RawHTTPError.malformed("Missing status line")
                }
                let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let code = Int(parts[1]) else {
                    throw RawHTTPError.malformed("Invalid status line: \(statusLine)")
                }
                var headers: [KeyValue] = []
                var cookies: [String] = []
                for line in lines.dropFirst() where !line.isEmpty {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers.append(KeyValue(key: name, value: value))
                    if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                        cookies.append(value)
                    }
                }
                return RawHead(statusCode: code, headers: headers, setCookies: cookies, bodyPrefix: rest)
            }
            if buffer.count > 1_048_576 {
                throw RawHTTPError.malformed("Response headers exceed 1 MB")
            }
            guard let chunk = try readSome() else {
                throw RawHTTPError.closed
            }
            buffer.append(chunk)
        }
    }

    mutating func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        if !buffer.isEmpty {
            let take = min(count, buffer.count)
            result.append(buffer.prefix(take))
            buffer.removeFirst(take)
        }
        while result.count < count {
            guard let chunk = try readSome() else {
                throw RawHTTPError.closed
            }
            let take = min(count - result.count, chunk.count)
            result.append(chunk.prefix(take))
            if take < chunk.count {
                buffer.append(chunk.dropFirst(take))
            }
        }
        return result
    }

    mutating func readUntilEOF() throws -> Data {
        var result = Data()
        while let chunk = try readSome() {
            result.append(chunk)
        }
        return result
    }

    mutating func readChunked(prefix: Data) throws -> Data {
        buffer = prefix
        var result = Data()
        while true {
            let line = try readLine()
            let sizeText = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw RawHTTPError.malformed("Invalid chunk size: \(line)")
            }
            if size == 0 {
                while true {
                    do {
                        if try readLine().isEmpty { break }
                    } catch {
                        break
                    }
                }
                break
            }
            result.append(try readExactly(size))
            _ = try readExactly(2)
        }
        return result
    }

    private mutating func readLine() throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[..<range.lowerBound]
                let consumed = buffer.distance(from: buffer.startIndex, to: range.upperBound)
                buffer.removeFirst(consumed)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard let chunk = try readSome() else {
                throw RawHTTPError.closed
            }
            buffer.append(chunk)
        }
    }

    private mutating func readSome() throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count > 0 {
                return Data(bytes[0..<count])
            }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw RawHTTPError.timeout
            }
            throw RawHTTPError.connect("Read failed (errno \(errno))")
        }
    }
}
