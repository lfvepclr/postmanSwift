import Foundation
import Darwin

enum MockServerError: LocalizedError {
    case socket(String)
    case bind(String)
    case listen(String)

    var errorDescription: String? {
        switch self {
        case .socket(let detail): return "Mock server socket error: \(detail)"
        case .bind(let detail): return "Mock server could not bind to 127.0.0.1: \(detail)"
        case .listen(let detail): return "Mock server could not listen: \(detail)"
        }
    }
}

final class MockServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var lastError: String?
    @Published private(set) var requestCount = 0
    @Published private(set) var lastRequest: String?

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "postmanswift.mock.accept")
    private let handleQueue = DispatchQueue(label: "postmanswift.mock.handle", attributes: .concurrent)
    private let lock = NSLock()
    private struct RouteIndex {
        var byMethod: [String: MockCase] = [:]
        var anyMethod: [String: MockCase] = [:]
    }
    private var routes = RouteIndex()
    private var active = false

    func start(port: UInt16, services: [MockService]) throws {
        stop()
        lock.lock()
        routes = Self.makeIndex(services)
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockServerError.socket(lastErrno()) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = lastErrno()
            Darwin.close(fd)
            throw MockServerError.bind(message)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let message = lastErrno()
            Darwin.close(fd)
            throw MockServerError.listen(message)
        }

        listenFD = fd
        active = true
        DispatchQueue.main.async {
            self.port = port
            self.isRunning = true
            self.lastError = nil
            self.requestCount = 0
            self.lastRequest = nil
        }
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        active = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    func update(services: [MockService]) {
        let index = Self.makeIndex(services)
        lock.lock()
        routes = index
        lock.unlock()
    }

    /// Flattens enabled services into method+path lookups once per edit instead of scanning every
    /// service and case on each request.
    private static func makeIndex(_ services: [MockService]) -> RouteIndex {
        var index = RouteIndex()
        for service in services where service.enabled {
            let prefix = service.normalizedPrefix
            for mockCase in service.cases {
                let fullPath = prefix == "/" ? mockCase.normalizedPath : prefix + mockCase.normalizedPath
                let method = mockCase.method.uppercased()
                if method == "ANY" {
                    if index.anyMethod[fullPath] == nil { index.anyMethod[fullPath] = mockCase }
                } else {
                    let key = method + " " + fullPath
                    if index.byMethod[key] == nil { index.byMethod[key] = mockCase }
                }
            }
        }
        return index
    }

    func matchCase(method: String, path: String) -> MockCase? {
        lock.lock()
        let snapshot = routes
        lock.unlock()
        return snapshot.byMethod[method.uppercased() + " " + path] ?? snapshot.anyMethod[path]
    }

    private func acceptLoop() {
        while active {
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddress, &length)
            if client < 0 {
                if !active { break }
                if errno == EINTR { continue }
                break
            }
            handleQueue.async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(client: client) else {
            return
        }
        let path = request.path
        let method = request.method.uppercased()

        if path == "/_mock/health" {
            let body = #"{"ok":true,"service":"PostmanSwift Mock","port":\#(port)}"#
            respond(client: client, status: 200, headers: [KeyValue(key: "Content-Type", value: "application/json")], body: body)
            return
        }

        let matchedCase = matchCase(method: method, path: path)

        if let mockCase = matchedCase {
            if mockCase.delayMilliseconds > 0 {
                usleep(useconds_t(min(mockCase.delayMilliseconds, 30_000)) * 1000)
            }
            let expanded = expand(mockCase.body, request: request)
            var headers = mockCase.headers.filter(\.isEnabled)
            if !headers.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                headers.append(KeyValue(key: "Content-Type", value: "application/json"))
            }
            headers.append(KeyValue(key: "Access-Control-Allow-Origin", value: "*"))
            headers.append(KeyValue(key: "X-Mock-Case", value: mockCase.name))
            respond(client: client, status: mockCase.effectiveStatusCode, headers: headers, body: expanded)
            log("\(method) \(path) → \(mockCase.effectiveStatusCode) \(mockCase.name)")
        } else if method == "OPTIONS" {
            respond(client: client, status: 204, headers: [
                KeyValue(key: "Access-Control-Allow-Origin", value: "*"),
                KeyValue(key: "Access-Control-Allow-Methods", value: "GET, POST, PUT, PATCH, DELETE, OPTIONS"),
                KeyValue(key: "Access-Control-Allow-Headers", value: "*")
            ], body: "")
            log("OPTIONS \(path) → 204")
        } else {
            let body = #"{"code":40400,"message":"No mock case for \#(method) \#(path)"}"#
            respond(client: client, status: 404, headers: [KeyValue(key: "Content-Type", value: "application/json")], body: body)
            log("\(method) \(path) → 404")
        }
    }

    private struct IncomingRequest {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: String
    }

    private func readRequest(client: Int32) -> IncomingRequest? {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            data.append(contentsOf: buffer[0..<count])
            if data.count > 1_048_576 { return nil }
        }
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        var bodyData = Data(data[headerRange.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while bodyData.count < contentLength {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            bodyData.append(contentsOf: buffer[0..<count])
        }
        let body = String(decoding: bodyData.prefix(contentLength), as: UTF8.self)
        let pathPart = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pathPart.first ?? "/")
        let query = pathPart.count > 1 ? String(pathPart[1]) : ""
        return IncomingRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func expand(_ template: String, request: IncomingRequest) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{request.method}}", with: request.method)
        result = result.replacingOccurrences(of: "{{request.path}}", with: request.path)
        result = result.replacingOccurrences(of: "{{request.query}}", with: request.query)
        result = result.replacingOccurrences(of: "{{request.body}}", with: request.body)
        let bodyJSON: String
        if let data = request.body.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            bodyJSON = request.body.isEmpty ? "null" : request.body
        } else if let data = try? JSONSerialization.data(withJSONObject: request.body, options: [.fragmentsAllowed]),
                  let encoded = String(data: data, encoding: .utf8) {
            bodyJSON = encoded
        } else {
            bodyJSON = "null"
        }
        result = result.replacingOccurrences(of: "{{request.bodyJson}}", with: bodyJSON)
        return result
    }

    private func respond(client: Int32, status: Int, headers: [KeyValue], body: String) {
        let data = Data(body.utf8)
        var lines = ["HTTP/1.1 \(status) \(HTTPClient.reason(for: status))"]
        var hasLength = false
        for header in headers where header.isEnabled && !header.key.isEmpty {
            if header.key.caseInsensitiveCompare("Content-Length") == .orderedSame { hasLength = true }
            lines.append("\(header.key): \(header.value)")
        }
        if !hasLength { lines.append("Content-Length: \(data.count)") }
        lines.append("Connection: close")
        lines.append("Server: PostmanSwift-Mock")
        var response = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(data)
        writeAll(client: client, data: response)
    }

    private func writeAll(client: Int32, data: Data) {
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = send(client, base.advanced(by: offset), data.count - offset, 0)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.requestCount += 1
            self.lastRequest = message
        }
    }

    private func lastErrno() -> String {
        String(cString: strerror(errno))
    }
}
