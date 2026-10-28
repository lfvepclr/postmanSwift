import XCTest
@testable import PostmanSwift

final class VariableResolverTests: XCTestCase {
    func testPrecedence() {
        var context = VariableContext()
        context.globals = ["host": "global.example", "token": "global"]
        context.collection = ["host": "collection.example", "token": "collection"]
        context.environment = ["host": "env.example", "token": "environment"]
        context.data = ["token": "data"]
        context.local = ["token": "local"]

        XCTAssertEqual(context.resolve("{{host}}"), "env.example")
        XCTAssertEqual(context.resolve("{{token}}"), "local")
        XCTAssertEqual(context.resolve("https://{{host}}/api"), "https://env.example/api")
    }

    func testNestedAndMissing() {
        var context = VariableContext()
        context.environment = ["base": "{{scheme}}://{{host}}", "scheme": "https", "host": "api.example.com"]
        XCTAssertEqual(context.resolve("{{base}}/v1"), "https://api.example.com/v1")
        XCTAssertEqual(context.resolve("{{missing}}"), "{{missing}}")
    }

    func testDynamicVariablesAreStableWithinProvider() {
        let provider = DynamicVariableProvider()
        let context = VariableContext()
        let first = context.resolve("{{$guid}}", dynamic: provider)
        let second = context.resolve("{{$guid}}", dynamic: provider)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 36)
        XCTAssertNotNil(Int(context.resolve("{{$timestamp}}")))
    }
}

final class URLUtilitiesTests: XCTestCase {
    func testQueryParsingAndBuilding() {
        let params = URLUtilities.parseQuery(from: "https://example.com/search?q=hello%20world&page=2&empty=")
        XCTAssertEqual(params.count, 3)
        XCTAssertEqual(params[0].key, "q")
        XCTAssertEqual(params[0].value, "hello world")
        let rebuilt = URLUtilities.buildRaw(base: "https://example.com/search", params: params)
        XCTAssertTrue(rebuilt.contains("q=hello%20world"))
        XCTAssertTrue(rebuilt.contains("page=2"))
    }

    func testVariablePlaceholdersSurviveEncoding() {
        let value = URLUtilities.encodeQueryComponent("{{token}}")
        XCTAssertEqual(value, "{{token}}")
    }
}

final class ImportExportTests: XCTestCase {
    private let collectionJSON = """
    {
      "info": {
        "_postman_id": "c1",
        "name": "Demo",
        "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
      },
      "item": [
        {
          "name": "Folder",
          "item": [
            {
              "name": "Create User",
              "request": {
                "method": "POST",
                "header": [{"key": "Content-Type", "value": "application/json"}],
                "body": {"mode": "raw", "raw": "{\\"name\\":\\"Ada\\"}"},
                "url": {"raw": "{{baseUrl}}/users?active=true"},
                "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}"}]}
              },
              "event": [
                {"listen": "test", "script": {"exec": ["pm.test('ok', function () { pm.response.to.have.status(201); });"]}}
              ]
            }
          ]
        }
      ],
      "variable": [{"key": "baseUrl", "value": "https://api.example.com"}]
    }
    """

    func testCollectionRoundTrip() throws {
        let result = try ImportExport.decode(data: Data(collectionJSON.utf8), filename: "demo.json")
        XCTAssertEqual(result.collections.count, 1)
        let collection = result.collections[0]
        XCTAssertEqual(collection.info.name, "Demo")
        XCTAssertEqual(CollectionTree.flatten(collection).count, 1)
        let reference = CollectionTree.flatten(collection)[0]
        XCTAssertEqual(reference.item.name, "Create User")
        XCTAssertEqual(reference.item.request?.method, "POST")
        XCTAssertEqual(reference.item.testScript.contains("pm.test"), true)
        XCTAssertEqual(reference.effectiveAuth.type, "bearer")
        XCTAssertEqual(reference.item.request?.url?.query?.first?.value, "true")

        let exported = try ImportExport.encodeCollection(collection)
        let reimported = try ImportExport.decode(data: exported, filename: "export.json")
        XCTAssertEqual(reimported.collections.first?.items.count, 1)
    }

    func testEnvironmentEnabledFlag() throws {
        let json = """
        {"id":"e1","name":"Local","values":[{"key":"a","value":"1","enabled":true},{"key":"b","value":"2","enabled":false}]}
        """
        let result = try ImportExport.decode(data: Data(json.utf8), filename: "env.json")
        XCTAssertEqual(result.environments.count, 1)
        XCTAssertTrue(result.environments[0].values[0].isEnabled)
        XCTAssertFalse(result.environments[0].values[1].isEnabled)
    }

    func testCurlImport() throws {
        let command = "curl -X POST 'https://api.example.com/users?active=true' -H 'Content-Type: application/json' -H 'Authorization: Bearer abc' -d '{\"name\":\"Ada\"}'"
        let result = try ImportExport.decode(data: Data(command.utf8), filename: "request.txt")
        let reference = CollectionTree.flatten(result.collections[0])[0]
        XCTAssertEqual(reference.item.request?.method, "POST")
        XCTAssertEqual(reference.item.request?.rawURL.contains("active=true"), true)
        XCTAssertEqual(reference.item.request?.body?.raw, "{\"name\":\"Ada\"}")
        XCTAssertEqual(reference.item.request?.header?.count, 2)
    }

    func testOpenAPIImport() throws {
        let json = """
        {"openapi":"3.0.0","info":{"title":"Pets"},"servers":[{"url":"https://pets.example.com"}],
         "paths":{"/pets":{"get":{"summary":"List pets","parameters":[{"name":"limit","in":"query","schema":{"type":"integer"}}]}}}}
        """
        let result = try ImportExport.decode(data: Data(json.utf8), filename: "openapi.json")
        XCTAssertEqual(result.collections.first?.info.name, "Pets")
        let request = CollectionTree.flatten(result.collections[0])[0].item.request
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.rawURL, "https://pets.example.com/pets")
        XCTAssertEqual(request?.url?.query?.first?.key, "limit")
    }
}

final class RequestBuilderTests: XCTestCase {
    func testVariablesHeadersAndBearerAuth() throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = "https://{{host}}/users"
        draft.params = [KeyValue(key: "page", value: "{{page}}")]
        draft.headers = [KeyValue(key: "X-Trace", value: "{{trace}}"), KeyValue(key: "Disabled", value: "x", disabled: true)]
        draft.bodyMode = .raw
        draft.rawLanguage = .json
        draft.rawBody = "{\"id\":\"{{id}}\"}"
        draft.auth = Auth(type: "bearer")
        draft.auth.setValue("{{token}}", for: "token")

        var context = VariableContext()
        context.environment = ["host": "api.example.com", "page": "2", "trace": "abc", "id": "42", "token": "secret"]

        let prepared = try RequestBuilder.build(draft: draft, context: context, settings: AppSettings(), cookies: nil)
        XCTAssertEqual(prepared.url.absoluteString, "https://api.example.com/users?page=2")
        XCTAssertEqual(RequestBuilder.headerValue("X-Trace", in: prepared.headers), "abc")
        XCTAssertNil(RequestBuilder.headerValue("Disabled", in: prepared.headers))
        XCTAssertEqual(RequestBuilder.headerValue("Authorization", in: prepared.headers), "Bearer secret")
        XCTAssertEqual(String(data: prepared.body ?? Data(), encoding: .utf8), "{\"id\":\"42\"}")
        XCTAssertEqual(RequestBuilder.headerValue("Content-Type", in: prepared.headers), "application/json")
    }

    func testAPIKeyInQuery() throws {
        var draft = RequestDraft()
        draft.urlRaw = "https://example.com/data?existing=1"
        draft.params = [KeyValue(key: "existing", value: "1")]
        draft.auth = Auth(type: "apikey")
        draft.auth.setValue("api_key", for: "key")
        draft.auth.setValue("123", for: "value")
        draft.auth.setValue("query", for: "in")
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        XCTAssertTrue(prepared.url.absoluteString.contains("existing=1"))
        XCTAssertTrue(prepared.url.absoluteString.contains("api_key=123"))
    }

    func testBasicAuthAndGraphQL() throws {
        var draft = RequestDraft()
        draft.method = "POST"
        draft.urlRaw = "https://example.com/graphql"
        draft.bodyMode = .graphql
        draft.graphqlQuery = "query { viewer { id } }"
        draft.graphqlVariables = "{\"x\":1}"
        draft.auth = Auth(type: "basic")
        draft.auth.setValue("user", for: "username")
        draft.auth.setValue("pass", for: "password")
        let prepared = try RequestBuilder.build(draft: draft, context: VariableContext(), settings: AppSettings(), cookies: nil)
        XCTAssertEqual(RequestBuilder.headerValue("Authorization", in: prepared.headers), "Basic dXNlcjpwYXNz")
        let body = try JSONSerialization.jsonObject(with: prepared.body ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["query"] as? String, "query { viewer { id } }")
        XCTAssertNotNil(body?["variables"])
    }
}

final class CollectionTreeTests: XCTestCase {
    func testInheritedScriptOrdering() {
        var folderItem = CollectionItem(name: "Create", request: RequestDef(method: "GET", url: "https://example.com"))
        folderItem.id = "request-1"
        folderItem.event = nil
        var folder = CollectionItem(name: "Folder", request: nil, item: [folderItem])
        folder.id = "folder-1"
        folder.event = [
            PMEvent(listen: "prerequest", script: PMEvent.Script(exec: ["folder-pre"])),
            PMEvent(listen: "test", script: PMEvent.Script(exec: ["folder-test"]))
        ]
        var collection = PMCollection(name: "C", items: [folder])
        collection.event = [
            PMEvent(listen: "prerequest", script: PMEvent.Script(exec: ["collection-pre"])),
            PMEvent(listen: "test", script: PMEvent.Script(exec: ["collection-test"]))
        ]

        let scripts = CollectionTree.scripts(collection: collection, itemID: "request-1")
        XCTAssertEqual(scripts.preRequest, ["collection-pre", "folder-pre"])
        XCTAssertEqual(scripts.tests, ["folder-test", "collection-test"])
        XCTAssertEqual(CollectionTree.effectiveAuth(collection: collection, itemID: "request-1").type, "noauth")

        collection.auth = Auth(type: "basic")
        XCTAssertEqual(CollectionTree.effectiveAuth(collection: collection, itemID: "request-1").type, "basic")
    }
}

final class ScriptRunnerTests: XCTestCase {
    func testPreRequestSetsVariable() {
        let request = PreparedRequest(method: "GET", url: URL(string: "https://example.com")!, headers: [], body: nil)
        let runner = ScriptRunner(settings: AppSettings(), cookieJar: nil)
        let outcome = runner.run(
            source: "pm.environment.set('token', 'abc'); pm.variables.set('local', '1');",
            phase: .preRequest,
            context: VariableContext(),
            request: request,
            response: nil,
            info: ScriptInfo(requestName: "T", requestID: "1", eventName: "prerequest")
        )
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.mutations.contains(where: { $0.scope == .environment && $0.key == "token" && $0.value == "abc" }))
        XCTAssertTrue(outcome.mutations.contains(where: { $0.scope == .variables && $0.key == "local" }))
    }

    func testTestsAndAssertions() {
        let request = PreparedRequest(method: "GET", url: URL(string: "https://example.com")!, headers: [], body: nil)
        let result = HTTPResult(
            statusCode: 200,
            statusText: "OK",
            headers: [KeyValue(key: "Content-Type", value: "application/json")],
            body: Data("{\"token\":\"xyz\",\"count\":3}".utf8),
            duration: 0.12,
            finalURL: URL(string: "https://example.com")!,
            mimeType: "application/json",
            redirects: []
        )
        let runner = ScriptRunner(settings: AppSettings(), cookieJar: nil)
        let outcome = runner.run(
            source: """
            pm.test("status is 200", function () { pm.response.to.have.status(200); });
            pm.test("json field", function () { pm.expect(pm.response.json().token).to.equal("xyz"); });
            pm.test("body contains", function () { pm.expect(pm.response.text()).to.include("count"); });
            pm.test("deliberate failure", function () { pm.expect(1).to.equal(2); });
            pm.environment.set("saved", pm.response.json().token);
            """,
            phase: .test,
            context: VariableContext(),
            request: request,
            response: result,
            info: ScriptInfo(requestName: "T", requestID: "1", eventName: "test")
        )
        XCTAssertEqual(outcome.tests.count, 4)
        XCTAssertEqual(outcome.tests.filter(\.passed).count, 3)
        XCTAssertTrue(outcome.mutations.contains(where: { $0.key == "saved" && $0.value == "xyz" }))
    }


    func testScriptGlobalsDoNotLeakBetweenRuns() {
        let request = PreparedRequest(method: "GET", url: URL(string: "https://example.com")!, headers: [], body: nil)
        let runner = ScriptRunner(settings: AppSettings(), cookieJar: nil)
        let info = ScriptInfo(requestName: "T", requestID: "1", eventName: "test")

        let first = runner.run(
            source: "var leakedGlobal = 42; pm.test('defines global', function () { pm.expect(leakedGlobal).to.equal(42); });",
            phase: .test,
            context: VariableContext(),
            request: request,
            response: nil,
            info: info
        )
        XCTAssertNil(first.error)
        XCTAssertEqual(first.tests.filter(\.passed).count, 1)

        let second = runner.run(
            source: "pm.test('global is isolated', function () { pm.expect(typeof leakedGlobal).to.equal('undefined'); });",
            phase: .test,
            context: VariableContext(),
            request: request,
            response: nil,
            info: info
        )
        XCTAssertNil(second.error)
        XCTAssertEqual(second.tests.count, 1)
        XCTAssertTrue(second.tests[0].passed)
    }

    func testCryptoJSAndLegacyRequestCompatibility() {
        let request = PreparedRequest(
            method: "POST",
            url: URL(string: "https://example.com/api?app_key=KEY123&format=json")!,
            headers: [],
            body: Data("{\"a\":1}".utf8)
        )
        let runner = ScriptRunner(settings: AppSettings(), cookieJar: nil)
        let outcome = runner.run(
            source: """
            var sign = CryptoJS.MD5("abc").toString();
            var appKey = pm.request.url.query.get("app_key").toString();
            var bodyString = request.data.toString();
            var parsedA = request.data.a;
            var fullURL = request.url.toString();
            var queryObject = JSON.stringify(pm.request.url.query.toObject());
            postman.setEnvironmentVariable("sign", sign);
            postman.setEnvironmentVariable("app_key", appKey);
            postman.setEnvironmentVariable("body", bodyString);
            postman.setEnvironmentVariable("parsedA", String(parsedA));
            postman.setEnvironmentVariable("url", fullURL);
            postman.setEnvironmentVariable("query", queryObject);
            """,
            phase: .preRequest,
            context: VariableContext(),
            request: request,
            response: nil,
            info: ScriptInfo(requestName: "Crypto", requestID: "1", eventName: "prerequest")
        )
        XCTAssertNil(outcome.error)
        let values = Dictionary(uniqueKeysWithValues: outcome.mutations.compactMap { mutation in
            mutation.value.map { (mutation.key, $0) }
        })
        XCTAssertEqual(values["sign"], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(values["app_key"], "KEY123")
        XCTAssertEqual(values["body"], "{\"a\":1}")
        XCTAssertEqual(values["parsedA"], "1")
        XCTAssertTrue(values["url"]?.contains("app_key=KEY123") ?? false)
        XCTAssertEqual(values["query"], "{\"app_key\":\"KEY123\",\"format\":\"json\"}")
    }

    func testMaterializePersistsScripts() throws {
        var item = CollectionItem(name: "Test", request: RequestDef())
        var draft = RequestDraft()
        draft.name = "Test"
        draft.method = "POST"
        draft.urlRaw = "https://example.com"
        draft.bodyMode = .raw
        draft.rawBody = "{\"x\":1}"
        draft.preRequestScript = "pm.environment.set('a', '1');"
        draft.testScript = "pm.test('ok', function () { pm.expect(1).to.equal(1); });"
        draft.materialize(into: &item)

        XCTAssertEqual(item.preRequestScript, draft.preRequestScript)
        XCTAssertEqual(item.testScript, draft.testScript)
        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CollectionItem.self, from: encoded)
        XCTAssertEqual(decoded.preRequestScript, draft.preRequestScript)
        XCTAssertEqual(decoded.testScript, draft.testScript)
        XCTAssertEqual(decoded.request?.body?.raw, draft.rawBody)
    }

    func testRequestMutation() {        let request = PreparedRequest(method: "GET", url: URL(string: "https://example.com/a")!, headers: [], body: nil)
        let runner = ScriptRunner(settings: AppSettings(), cookieJar: nil)
        let outcome = runner.run(
            source: "pm.request.headers.add({ key: 'X-Added', value: 'yes' });",
            phase: .preRequest,
            context: VariableContext(),
            request: request,
            response: nil,
            info: ScriptInfo(requestName: "T", requestID: "1", eventName: "prerequest")
        )
        XCTAssertTrue(outcome.requestMutation?.headers?.contains(where: { $0.key == "X-Added" }) ?? false)
    }
}
