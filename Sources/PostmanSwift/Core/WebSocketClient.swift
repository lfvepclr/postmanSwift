import Foundation

struct WebSocketMessage: Identifiable, Hashable {
    enum Direction {
        case sent
        case received
        case system
    }

    var id = UUID()
    var direction: Direction
    var text: String
    var timestamp = Date()
    var isBinary = false
}

final class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum State: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case closing = "Closing"
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var messages: [WebSocketMessage] = []
    @Published private(set) var error: String?
    @Published private(set) var negotiatedProtocol: String?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var verifySSL = true

    var isConnected: Bool { state == .connected }

    func connect(url: URL, headers: [KeyValue], cookies: CookieJar?, settings: AppSettings) {
        disconnect()
        verifySSL = settings.sslVerification
        error = nil
        negotiatedProtocol = nil
        state = .connecting

        var request = URLRequest(url: url)
        for header in headers where header.isEnabled && !header.key.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if settings.sendCookies, let cookies, let cookie = cookies.headerValue(for: url),
           request.value(forHTTPHeaderField: "Cookie") == nil {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(request.value(forHTTPHeaderField: "User-Agent") ?? "PostmanSwift/1.0", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        self.session = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        receiveNext()
    }

    func disconnect() {
        state = .closing
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if state != .disconnected {
            state = .disconnected
        }
    }

    func send(_ text: String) {
        guard let task else {
            error = "WebSocket is not connected."
            return
        }
        task.send(.string(text)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.error = error.localizedDescription
                    self.append(.init(direction: .system, text: "Send failed: \(error.localizedDescription)"))
                }
            }
        }
        append(WebSocketMessage(direction: .sent, text: text))
    }

    func sendPing() {
        task?.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.error = error.localizedDescription
                } else {
                    self.append(WebSocketMessage(direction: .system, text: "Ping sent"))
                }
            }
        }
    }

    func clearMessages() {
        messages.removeAll()
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                DispatchQueue.main.async {
                    switch message {
                    case .string(let text):
                        self.append(WebSocketMessage(direction: .received, text: text))
                    case .data(let data):
                        let preview = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>"
                        self.append(WebSocketMessage(direction: .received, text: preview, isBinary: true))
                    @unknown default:
                        break
                    }
                }
                self.receiveNext()
            case .failure(let error):
                DispatchQueue.main.async {
                    if self.state != .disconnected {
                        self.error = error.localizedDescription
                        self.append(WebSocketMessage(direction: .system, text: "Connection closed: \(error.localizedDescription)"))
                        self.state = .disconnected
                    }
                }
            }
        }
    }

    private func append(_ message: WebSocketMessage) {
        messages.append(message)
        if messages.count > 1000 {
            messages.removeFirst(messages.count - 1000)
        }
    }

    // MARK: - URLSession delegates

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        DispatchQueue.main.async {
            self.state = .connected
            self.negotiatedProtocol = `protocol`
            self.append(WebSocketMessage(direction: .system, text: "Connected" + (`protocol`.map { " · \($0)" } ?? "")))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        DispatchQueue.main.async {
            self.state = .disconnected
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.append(WebSocketMessage(direction: .system, text: "Closed (\(closeCode.rawValue))" + (reasonText.isEmpty ? "" : ": \(reasonText)")))
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           !verifySSL,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
