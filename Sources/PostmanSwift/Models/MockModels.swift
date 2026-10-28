import Foundation

struct MockCase: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = "New Case"
    var method: String = "GET"
    var path: String = "/"
    var statusCode: Int = 200
    var headers: [KeyValue] = [KeyValue(key: "Content-Type", value: "application/json")]
    var body: String = "{\n  \"ok\": true\n}"
    var requestBody: String = "{\n  \"test\": true\n}"
    var delayMilliseconds: Int = 0

    var normalizedPath: String {
        path.hasPrefix("/") ? path : "/" + path
    }

    var effectiveStatusCode: Int {
        min(599, max(100, statusCode))
    }
}

struct MockService: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = "New Service"
    var prefix: String = "/api"
    var enabled: Bool = true
    var cases: [MockCase] = []

    var normalizedPrefix: String {
        var value = prefix.trimmingCharacters(in: .whitespaces)
        if !value.hasPrefix("/") { value = "/" + value }
        if value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }
}

enum MockDefaults {
    static func services() -> [MockService] {
        let ok = MockCase(
            name: "Success",
            method: "GET",
            path: "/users/ok",
            statusCode: 200,
            body: "{\n  \"code\": 0,\n  \"message\": \"ok\",\n  \"data\": { \"id\": 1, \"name\": \"Ada\" }\n}"
        )
        let created = MockCase(
            name: "Created",
            method: "POST",
            path: "/users",
            statusCode: 201,
            body: "{\n  \"code\": 0,\n  \"message\": \"created\",\n  \"data\": { \"id\": 2 }\n}"
        )
        let bad = MockCase(
            name: "Bad Request",
            method: "GET",
            path: "/users/bad-request",
            statusCode: 400,
            body: "{\n  \"code\": 40001,\n  \"message\": \"invalid parameter\"\n}"
        )
        let unauthorized = MockCase(
            name: "Unauthorized",
            method: "GET",
            path: "/users/unauthorized",
            statusCode: 401,
            body: "{\n  \"code\": 40100,\n  \"message\": \"token expired\"\n}"
        )
        let serverError = MockCase(
            name: "Server Error",
            method: "GET",
            path: "/users/server-error",
            statusCode: 500,
            body: "{\n  \"code\": 50000,\n  \"message\": \"internal error\"\n}"
        )
        let slow = MockCase(
            name: "Slow (2s)",
            method: "GET",
            path: "/users/slow",
            statusCode: 200,
            body: "{\n  \"code\": 0,\n  \"message\": \"slow response\"\n}",
            delayMilliseconds: 2000
        )
        let echo = MockCase(
            name: "Echo",
            method: "POST",
            path: "/echo",
            statusCode: 200,
            body: "{\n  \"method\": \"{{request.method}}\",\n  \"path\": \"{{request.path}}\",\n  \"body\": {{request.bodyJson}}\n}"
        )
        return [MockService(name: "Demo Mock", prefix: "/api", cases: [ok, created, bad, unauthorized, serverError, slow, echo])]
    }
}
