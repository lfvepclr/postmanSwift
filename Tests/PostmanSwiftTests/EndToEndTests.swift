import XCTest
@testable import PostmanSwift

final class EndToEndTests: XCTestCase {
    private var server: Process?
    private var baseURL: URL!
    private var scriptURL: URL!

    private let serverSource = #"""
    import http.server, json, time, sys

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _send(self, code, body=b"", ctype="application/json", extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            if extra:
                for key, value in extra.items():
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith("/json"):
                body = json.dumps({"ok": True, "token": "abc123", "count": 3}).encode()
                self._send(200, body)
            elif self.path.startswith("/redirect"):
                self._send(302, b"", extra={"Location": "/json"})
            elif self.path.startswith("/set-cookie"):
                self._send(200, b'{"cookie":true}', extra={"Set-Cookie": "session=xyz; Path=/; HttpOnly"})
            elif self.path.startswith("/slow"):
                time.sleep(0.15)
                self._send(200, b'{"slow":true}')
            elif self.path.startswith("/chunked"):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for part in [b'{"chunked":', b'true,"n":', b'3}']:
                    self.wfile.write(("%x\r\n" % len(part)).encode() + part + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            elif self.path.startswith("/status/"):
                code = int(self.path.split("/")[-1])
                self._send(code, json.dumps({"status": code}).encode())
            else:
                self._send(404, b'{"error":"not found"}')

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", "replace")
            payload = {"method": "POST", "path": self.path, "headers": dict(self.headers), "body": body}
            self._send(201, json.dumps(payload).encode())

    port = int(sys.argv[1])
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    """#

    override func setUp() async throws {
        try await super.setUp()
        let port = Int.random(in: 20000...42000)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("pn-server-\(UUID().uuidString).py")
        try serverSource.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, String(port)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        server = process

        let deadline = Date().addingTimeInterval(6)
        let healthRequest = PreparedRequest(
            method: "GET",
            url: baseURL.appendingPathComponent("json"),
            headers: [],
            body: nil
        )
        while Date() < deadline {
            if let result = try? await RawHTTPClient.send(healthRequest, settings: AppSettings(), cookieJar: nil),
               result.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTFail("Local test server did not start")
    }

    override func tearDown() async throws {
        server?.terminate()
        server?.waitUntilExit()
        if let scriptURL { try? FileManager.default.removeItem(at: scriptURL) }
        try await super.tearDown()
    }

    func testGETJSON() async throws {
        var draft = RequestDraft()
        draft.method = "GET"
        draft.urlRaw = baseURL.appendingPathComponent("json").absoluteString
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let client = HTTPClient(settings: AppSettings(), cookieJar: nil)
        let result = try await client.send(prepared)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.mimeType, "application/json")
        let object = try JSONSerialization.jsonObject(with: result.body) as? [String: Any]
        XCTAssertEqual(object?["token"] as? String, "abc123")
        XCTAssertGreaterThanOrEqual(result.duration, 0)
    }

    func testPOSTWithVariablesScriptsAndTests() async throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = "{{base}}/echo"
        draft.bodyMode = .raw
        draft.rawLanguage = .json
        draft.rawBody = "{\"name\":\"{{name}}\"}"
        draft.headers = [KeyValue(key: "Content-Type", value: "application/json")]
        draft.preRequestScript = "pm.request.headers.add({ key: 'X-From-Script', value: 'yes' });"
        draft.testScript = """
        pm.test("created", function () { pm.response.to.have.status(201); });
        pm.test("echo body", function () { pm.expect(pm.response.json().body).to.include("Ada"); });
        pm.environment.set("saved_token", pm.response.json().token || "none");
        """

        var context = VariableContext()
        context.environment = ["base": baseURL.absoluteString, "name": "Ada"]
        var settings = AppSettings()
        settings.followRedirects = true
        let output = await AppStore.performSend(
            draft: draft,
            auth: .none,
            context: context,
            settings: settings,
            cookies: CookieJar(),
            info: ScriptInfo(requestName: "Echo", requestID: "1", eventName: "test")
        )
        XCTAssertNil(output.error)
        XCTAssertEqual(output.result?.statusCode, 201)
        XCTAssertEqual(output.tests.count, 2)
        XCTAssertTrue(output.tests.allSatisfy(\.passed), output.tests.compactMap(\.errorMessage).joined(separator: "; "))
        XCTAssertTrue(output.mutations.contains(where: { $0.key == "saved_token" }))

        let echoed = try JSONSerialization.jsonObject(with: Data((output.responseText ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(echoed?["body"] as? String, "{\"name\":\"Ada\"}")
        let headers = echoed?["headers"] as? [String: Any] ?? [:]
        let headerKeys = headers.keys.map { $0.lowercased() }
        XCTAssertTrue(headerKeys.contains("x-from-script"))
    }

    func testRedirectFollowedAndStopped() async throws {
        var draft = RequestDraft()
        draft.urlRaw = baseURL.appendingPathComponent("redirect").absoluteString

        var follow = AppSettings()
        follow.followRedirects = true
        let preparedFollow = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: follow, cookies: nil)
        let followed = try await HTTPClient(settings: follow, cookieJar: nil).send(preparedFollow)
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(followed.redirects.count, 1)

        var stop = AppSettings()
        stop.followRedirects = false
        let preparedStop = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: stop, cookies: nil)
        let stopped = try await HTTPClient(settings: stop, cookieJar: nil).send(preparedStop)
        XCTAssertEqual(stopped.statusCode, 302)
    }

    func testCookieJarRoundTrip() async throws {
        let jar = CookieJar()
        var draft = RequestDraft()
        draft.urlRaw = baseURL.appendingPathComponent("set-cookie").absoluteString
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: jar)
        _ = try await HTTPClient(settings: AppSettings(), cookieJar: jar).send(prepared)
        XCTAssertTrue(jar.cookies.contains(where: { $0.name == "session" && $0.value == "xyz" }))

        var echoDraft = RequestDraft()
        echoDraft.method = "POST"
        echoDraft.urlRaw = baseURL.appendingPathComponent("echo").absoluteString
        let echoPrepared = try RequestBuilder.build(draft: echoDraft, context: VariableContext(), settings: AppSettings(), cookies: jar)
        XCTAssertTrue(RequestBuilder.headerValue("Cookie", in: echoPrepared.headers)?.contains("session=xyz") ?? false)
    }

    func testBearnerAndAPIKeyHeadersReachServer() async throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = baseURL.appendingPathComponent("echo").absoluteString
        draft.auth = Auth(type: "bearer")
        draft.auth.setValue("token-123", for: "token")
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let result = try await HTTPClient(settings: AppSettings(), cookieJar: nil).send(prepared)
        XCTAssertEqual(result.statusCode, 201)
        let object = try JSONSerialization.jsonObject(with: result.body) as? [String: Any]
        let headers = (object?["headers"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = String(describing: pair.value)
        }
        XCTAssertEqual(headers["authorization"], "Bearer token-123")
    }

    func testInheritedCollectionScriptsRun() async throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = baseURL.appendingPathComponent("echo").absoluteString
        var settings = AppSettings()
        settings.followRedirects = true

        let output = await AppStore.performSend(
            draft: draft,
            auth: .none,
            context: VariableContext(),
            settings: settings,
            cookies: CookieJar(),
            info: ScriptInfo(requestName: "Inherited", requestID: "2", eventName: "test"),
            inheritedPreRequest: [
                "pm.environment.set('from_collection', 'yes');",
                "pm.request.headers.add({ key: 'X-Collection', value: 'inherited' });"
            ],
            inheritedTests: [
                "pm.test('inherited status', function () { pm.response.to.have.status(201); });"
            ]
        )
        XCTAssertNil(output.error)
        XCTAssertEqual(output.result?.statusCode, 201)
        XCTAssertTrue(output.tests.contains(where: { $0.name == "inherited status" && $0.passed }))
        XCTAssertTrue(output.mutations.contains(where: { $0.key == "from_collection" && $0.value == "yes" }))

        let echoed = try JSONSerialization.jsonObject(with: Data((output.responseText ?? "").utf8)) as? [String: Any]
        let headers = echoed?["headers"] as? [String: Any] ?? [:]
        let headerKeys = headers.keys.map { $0.lowercased() }
        XCTAssertTrue(headerKeys.contains("x-collection"))
    }


    func testRawSocketTransportGETPOSTRedirectAndChunked() async throws {

        var getDraft = RequestDraft()
        getDraft.urlRaw = baseURL.appendingPathComponent("json").absoluteString
        let getPrepared = try RequestBuilder.build(draft: getDraft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let rawGet = try await RawHTTPClient.send(getPrepared, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(rawGet.statusCode, 200)
        XCTAssertEqual(rawGet.mimeType, "application/json")

        var postDraft = RequestDraft()
        postDraft.method = "POST"
        postDraft.urlRaw = baseURL.appendingPathComponent("echo").absoluteString
        postDraft.bodyMode = .raw
        postDraft.rawBody = "{\"raw\":true}"
        postDraft.headers = [KeyValue(key: "X-Raw", value: "yes")]
        let postPrepared = try RequestBuilder.build(draft: postDraft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let rawPost = try await RawHTTPClient.send(postPrepared, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(rawPost.statusCode, 201)
        let echoed = try JSONSerialization.jsonObject(with: rawPost.body) as? [String: Any]
        XCTAssertEqual(echoed?["body"] as? String, "{\"raw\":true}")

        var redirectDraft = RequestDraft()
        redirectDraft.urlRaw = baseURL.appendingPathComponent("redirect").absoluteString
        let redirectPrepared = try RequestBuilder.build(draft: redirectDraft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let followed = try await RawHTTPClient.send(redirectPrepared, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(followed.redirects.count, 1)

        var chunkedDraft = RequestDraft()
        chunkedDraft.urlRaw = baseURL.appendingPathComponent("chunked").absoluteString
        let chunkedPrepared = try RequestBuilder.build(draft: chunkedDraft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let chunked = try await RawHTTPClient.send(chunkedPrepared, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(chunked.statusCode, 200)
        let chunkedObject = try JSONSerialization.jsonObject(with: chunked.body) as? [String: Any]
        XCTAssertEqual(chunkedObject?["chunked"] as? Bool, true)
        XCTAssertEqual(chunkedObject?["n"] as? Int, 3)
    }

    func testRawSocketTransportCookies() async throws {
        let jar = CookieJar()
        var setDraft = RequestDraft()
        setDraft.urlRaw = baseURL.appendingPathComponent("set-cookie").absoluteString
        let setPrepared = try RequestBuilder.build(draft: setDraft, context: VariableContext(), settings: AppSettings(), cookies: jar)
        _ = try await RawHTTPClient.send(setPrepared, settings: AppSettings(), cookieJar: jar)
        XCTAssertTrue(jar.cookies.contains(where: { $0.name == "session" }))
    }

    func testCodeGeneratorProducesCurl() throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = "https://example.com/users"
        draft.bodyMode = .raw
        draft.rawBody = "{\"name\":\"Ada\"}"
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        let curl = CodeGenerator.generate(prepared, language: .curl)
        XCTAssertTrue(curl.contains("curl --request POST"))
        XCTAssertTrue(curl.contains("https://example.com/users"))
        XCTAssertTrue(curl.contains("--data-raw"))
    }
}
