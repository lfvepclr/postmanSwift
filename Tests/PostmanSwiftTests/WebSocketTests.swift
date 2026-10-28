import XCTest
@testable import PostmanSwift

final class WebSocketTests: XCTestCase {
    func testEchoRoundTrip() async throws {
        let server = try WebSocketEchoServer()
        server.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        let client = WebSocketClient()
        defer {
            client.disconnect()
            server.stop()
        }
        let url = URL(string: "ws://127.0.0.1:\(server.port)/echo")!
        client.connect(url: url, headers: [], cookies: nil, settings: AppSettings())

        for _ in 0..<80 {
            if client.state == .connected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(client.state, .connected, "WebSocket did not connect; error: \(client.error ?? "none")")

        client.send("hello-websocket")
        var received = false
        for _ in 0..<80 {
            if client.messages.contains(where: { $0.direction == .received && $0.text == "hello-websocket" }) {
                received = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(received, "Echo message was not received")
        XCTAssertTrue(client.messages.contains(where: { $0.direction == .sent && $0.text == "hello-websocket" }))
    }
}
