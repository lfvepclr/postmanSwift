import XCTest
@testable import PostmanSwift

final class MockAndCompletionTests: XCTestCase {
    func testCompletionDetection() {
        let variables = [
            VariableSuggestion(name: "baseUrl", value: "https://api.example.com", scope: "Environment", note: "API 根地址"),
            VariableSuggestion(name: "token", value: "abc", scope: "Globals", note: nil)
        ]
        let variableResult = CompletionEngine.detect(text: "{{ba", caret: 4, variables: variables, scriptAPI: false)
        XCTAssertEqual(variableResult?.items.count, 1)
        XCTAssertEqual(variableResult?.items.first?.insertText, "baseUrl}}")
        XCTAssertEqual(variableResult?.range, NSRange(location: 2, length: 2))

        let apiResult = CompletionEngine.detect(text: "pm.re", caret: 5, variables: variables, scriptAPI: true)
        XCTAssertTrue(apiResult?.items.contains(where: { $0.title == "request" }) ?? false)

        let nested = CompletionEngine.detect(text: "pm.request.url.query.", caret: 21, variables: variables, scriptAPI: true)
        XCTAssertTrue(nested?.items.contains(where: { $0.title == "upsert" }) ?? false)

        let pmOnly = CompletionEngine.detect(text: "pm.", caret: 3, variables: variables, scriptAPI: true)
        XCTAssertTrue(pmOnly?.items.allSatisfy { !$0.title.hasPrefix("{{") } ?? false)
        XCTAssertTrue(pmOnly?.items.contains(where: { $0.title == "environment" }) ?? false)
        XCTAssertNil(CompletionEngine.detect(text: "hello", caret: 5, variables: variables, scriptAPI: true))
    }

    func testVariableHighlightTokens() {
        let tokens = SyntaxHighlighter.tokens(in: "{\"a\": \"{{token}}\"}", language: .json)
        XCTAssertTrue(tokens.contains(where: { $0.color == NSColor.systemTeal }))
    }

    func testMockRouteIndex() {
        let server = MockServer()
        var service = MockService(name: "API", prefix: "/api")
        service.cases = [
            MockCase(name: "get-users", method: "GET", path: "/users"),
            MockCase(name: "any-users", method: "ANY", path: "/users"),
            MockCase(name: "delete-user", method: "DELETE", path: "/users")
        ]
        var disabled = MockService(name: "Off", prefix: "/off")
        disabled.enabled = false
        disabled.cases = [MockCase(name: "hidden", method: "GET", path: "/x")]
        server.update(services: [service, disabled])

        XCTAssertEqual(server.matchCase(method: "GET", path: "/api/users")?.name, "get-users")
        XCTAssertEqual(server.matchCase(method: "POST", path: "/api/users")?.name, "any-users")
        XCTAssertEqual(server.matchCase(method: "DELETE", path: "/api/users")?.name, "delete-user")
        XCTAssertEqual(server.matchCase(method: "PUT", path: "/api/users")?.name, "any-users")
        XCTAssertNil(server.matchCase(method: "GET", path: "/off/x"))

        var replacement = MockService(name: "API", prefix: "/v2")
        replacement.cases = [MockCase(name: "v2", method: "GET", path: "/users")]
        server.update(services: [replacement])
        XCTAssertNil(server.matchCase(method: "GET", path: "/api/users"))
        XCTAssertEqual(server.matchCase(method: "GET", path: "/v2/users")?.name, "v2")
    }

    func testMockServerRoutes() async throws {
        let server = MockServer()
        let port = UInt16.random(in: 20000...42000)
        try server.start(port: port, services: MockDefaults.services())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        let health = PreparedRequest(method: "GET", url: URL(string: base + "/_mock/health")!, headers: [], body: nil)
        var ready = false
        for _ in 0..<50 {
            if let result = try? await RawHTTPClient.send(health, settings: AppSettings(), cookieJar: nil), result.statusCode == 200 {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)

        let ok = PreparedRequest(method: "GET", url: URL(string: base + "/api/users/ok")!, headers: [], body: nil)
        let okResult = try await RawHTTPClient.send(ok, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(okResult.statusCode, 200)
        XCTAssertTrue(okResult.headers.contains(where: { $0.key == "X-Mock-Case" && $0.value == "Success" }))
        XCTAssertTrue(okResult.text?.contains("Ada") ?? false)

        let bad = PreparedRequest(method: "GET", url: URL(string: base + "/api/users/bad-request")!, headers: [], body: nil)
        let badResult = try await RawHTTPClient.send(bad, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(badResult.statusCode, 400)

        let echo = PreparedRequest(
            method: "POST",
            url: URL(string: base + "/api/echo")!,
            headers: [KeyValue(key: "Content-Type", value: "application/json")],
            body: Data("{\"hello\":\"world\"}".utf8)
        )
        let echoResult = try await RawHTTPClient.send(echo, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(echoResult.statusCode, 200)
        XCTAssertTrue(echoResult.text?.contains("hello") ?? false)

        let missing = PreparedRequest(method: "GET", url: URL(string: base + "/api/missing")!, headers: [], body: nil)
        let missingResult = try await RawHTTPClient.send(missing, settings: AppSettings(), cookieJar: nil)
        XCTAssertEqual(missingResult.statusCode, 404)
    }
}

final class HistoryLazyLoadTests: XCTestCase {
    func testHistoryKeepsResolvedRequestTimingAndSpilledBody() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        let source = directory.appendingPathComponent("spill.bin")
        let payload = Data(repeating: 0x42, count: 64_000)
        try payload.write(to: source)
        let resolved = ResolvedRequest(
            method: "GET",
            url: "https://api.test/users?x=1",
            headers: [KeyValue(key: "X-Token", value: "abc")],
            body: Data("req".utf8)
        )
        let timings = RequestTimings(
            dns: 1, connect: 2, tls: 3, request: 4, ttfb: 5, download: 6,
            total: 21, protocolName: "h2", remoteAddress: "1.2.3.4:443"
        )
        let entry = HistoryEntry(
            method: "GET",
            url: resolved.url,
            statusCode: 200,
            duration: 0.021,
            responseSize: payload.count,
            collectionID: "collection",
            collectionName: "Collection",
            requestName: "Resolved",
            request: RequestDef(),
            responseHeaders: [],
            responseBody: nil,
            responseText: nil,
            mimeType: "application/octet-stream",
            itemID: "item-1",
            resolvedRequest: resolved,
            timings: timings,
            responseBodySourceURL: source
        )
        store.insert(entry)

        let detail = try XCTUnwrap(store.latestDetail(itemID: "item-1"))
        XCTAssertEqual(detail.resolvedRequest?.method, resolved.method)
        XCTAssertEqual(detail.resolvedRequest?.url, resolved.url)
        XCTAssertEqual(detail.resolvedRequest?.headers.map(\.key), ["X-Token"])
        XCTAssertEqual(detail.resolvedRequest?.headers.map(\.value), ["abc"])
        XCTAssertEqual(detail.resolvedRequest?.body, resolved.body)
        XCTAssertEqual(detail.timings, timings)
        XCTAssertEqual(detail.responseBody, payload)
        let path = try XCTUnwrap(detail.responseBodyPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        store.delete(id: entry.id)
        XCTAssertNil(store.latestDetail(itemID: "item-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSummaryFetchSkipsBodiesAndDetailLoadsThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        let body = Data(repeating: 0x41, count: 2_000_000)
        var draft = RequestDraft()
        draft.name = "Huge body"
        draft.urlRaw = "https://example.com/huge"
        let entry = HistoryEntry(
            method: "GET",
            url: "https://example.com/huge",
            statusCode: 200,
            duration: 42,
            responseSize: body.count,
            requestName: "Huge body",
            request: draft.asRequestDef(),
            responseHeaders: [KeyValue(key: "Content-Type", value: "application/octet-stream")],
            responseBody: body,
            responseText: nil,
            mimeType: "application/octet-stream"
        )
        store.insert(entry)

        let summaries = store.fetch()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].isSummary)
        XCTAssertNil(summaries[0].responseBody)
        XCTAssertNil(summaries[0].responseText)
        XCTAssertEqual(summaries[0].request.url?.raw ?? "", "")

        let detail = store.fetchDetail(id: entry.id)
        XCTAssertEqual(detail?.responseBody?.count, body.count)
        XCTAssertEqual(detail?.requestName, "Huge body")
        XCTAssertEqual(detail?.responseHeaders.first?.key, "Content-Type")
        XCTAssertEqual(detail?.isSummary, false)
    }
}

final class DisplayTextTests: XCTestCase {
    func testWrapsVeryLongLinesWithoutLosingContent() {
        let raw = String(repeating: "QUJD", count: 2_000)
        let wrapped = DisplayText.wrapVeryLongLines(raw, column: 120)
        XCTAssertNotEqual(wrapped, raw)
        XCTAssertEqual(wrapped.filter { $0 != "\n" }, raw)
        XCTAssertLessThanOrEqual(wrapped.split(separator: "\n").map(\.count).max() ?? 0, 120)
    }

    func testLeavesNormalTextUntouched() {
        let text = "{\n  \"a\": 1,\n  \"b\": 2\n}"
        XCTAssertEqual(DisplayText.wrapVeryLongLines(text), text)
    }

    func testWrappingKeepsMultiByteCharactersIntact() {
        let raw = String(repeating: "中文数据", count: 1_000)
        let wrapped = DisplayText.wrapVeryLongLines(raw, column: 100)
        XCTAssertFalse(wrapped.unicodeScalars.contains(where: { $0 == "\u{FFFD}" }))
        XCTAssertEqual(wrapped.filter { $0 != "\n" }, raw)
    }
}

final class JSONTreeTests: XCTestCase {
    func testPreservesOrderAndDecodesEscapes() throws {
        let text = #"{"b":1,"a":[true,null,"x\u4e2d\n"],"nested":{"k":"v"}}"#
        let tree = try XCTUnwrap(JSONTreeParser.parse(text))
        guard case .object(let entries) = tree else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(entries.map(\.key), ["b", "a", "nested"])
        guard case .array(let items) = entries[1].value else {
            return XCTFail("expected array")
        }
        XCTAssertEqual(items.count, 3)
        guard case .string(let string) = items[2] else {
            return XCTFail("expected string")
        }
        XCTAssertEqual(string, "x中\n")
    }

    func testRejectsInvalidJSON() {
        XCTAssertNil(JSONTreeParser.parse("not json"))
        XCTAssertNil(JSONTreeParser.parse("{\"a\":}"))
        XCTAssertNil(JSONTreeParser.parse("{\"a\":1} trailing"))
        XCTAssertNil(JSONTreeParser.parse(""))
    }

    func testPDFRowsExpandToInlineViewer() throws {
        let pdf = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 256)
        let base64 = pdf.base64EncodedString()
        let json = "{\"file\":{\"data\":\"\(base64)\"},\"ok\":true}"
        let tree = try XCTUnwrap(JSONTreeParser.parse(json))
        XCTAssertNotNil(Base64PDF.byteCount(base64))

        let expanded = JSONTreeFlattener.defaultExpandedPaths(tree)
        XCTAssertTrue(expanded.contains("$"))
        XCTAssertTrue(expanded.contains("$/file#0"))
        XCTAssertTrue(expanded.contains("$/file#0/data#0"))

        let rows = JSONTreeFlattener.flatten(tree, expanded: expanded)
        XCTAssertTrue(rows.contains {
            if case .pdfView = $0.kind { return true }
            return false
        })
    }

    func testNumberLiteralIsPreserved() throws {
        let tree = try XCTUnwrap(JSONTreeParser.parse(#"{"n":1.2500e+3}"#))
        guard case .object(let entries) = tree, case .number(let literal) = entries[0].value else {
            return XCTFail("expected number")
        }
        XCTAssertEqual(literal, "1.2500e+3")
    }
}


final class JSONTreeMediaTests: XCTestCase {
    func testBase64ImageDetection() {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 200))
        let base64 = pngBytes.base64EncodedString()
        XCTAssertNotNil(Base64Image.byteCount("data:image/png;base64,\(base64)"))
        XCTAssertNotNil(Base64Image.byteCount(base64))
        XCTAssertEqual(Base64Image.cleaned("data:image/png;base64,\(base64)"), base64)
        XCTAssertNil(Base64Image.byteCount("JVBERi0xLjcK"))

        let pdf = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 256)
        XCTAssertNotNil(Base64PDF.byteCount(pdf.base64EncodedString()))
        XCTAssertNil(Base64PDF.byteCount("data:image/png;base64,\(base64)"))
    }

    func testLargeMediaStringsGetSmallPrecomputedPreviews() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 5_000))
        let imageBase64 = pngBytes.base64EncodedString()
        let pdfBase64 = (Data("%PDF-1.4\n".utf8) + Data(repeating: 0x42, count: 4_000)).base64EncodedString()
        let hugeText = String(repeating: "A", count: 4_000_000)
        let json = "{\"pdf\":\"\(pdfBase64)\",\"img\":\"data:image/png;base64,\(imageBase64)\",\"text\":\"\(hugeText)\"}"

        let start = Date()
        let tree = try XCTUnwrap(JSONTreeParser.parse(json))
        let presentation = JSONTreePresentation.make(root: tree)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)

        var sawImage = false
        var sawPDF = false
        for row in presentation.rows {
            switch row.kind {
            case .image(_, _, let preview, _):
                sawImage = true
                XCTAssertLessThan(preview.count, 120)
            case .pdf(_, _, let preview, _):
                sawPDF = true
                XCTAssertLessThan(preview.count, 120)
            case .string(let value, let display, let length):
                XCTAssertEqual(length, 4_000_000)
                XCTAssertEqual(value.count, 4_000_000)
                XCTAssertLessThan(display.count, 250)
            default:
                break
            }
        }
        XCTAssertTrue(sawImage)
        XCTAssertTrue(sawPDF)
    }

    func testImageIOThumbnailCapsPixelSize() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 32)
    }
}

final class PDFResponseTests: XCTestCase {    func testExtractsBase64PDFFromJSON() throws {
        let pdf = Data("%PDF-1.4\n%test\n1 0 obj\n<<>>\nendobj\n%%EOF".utf8)
        let base64 = pdf.base64EncodedString()
        let json = "{\"file\":{\"name\":\"report.pdf\",\"content\":\"\(base64)\"},\"ok\":true}"
        let pdfs = PDFExtractor.extract(text: json, mime: "application/json", body: Data(json.utf8))
        XCTAssertEqual(pdfs.count, 1)
        XCTAssertEqual(pdfs.first?.data, pdf)
        XCTAssertEqual(pdfs.first?.name, "pdf.file.content")
    }

    func testAbbreviatesBase64WithoutBreakingJSON() throws {
        let pdf = Data(repeating: 0x41, count: 4096)
        let base64 = "%PDF-1.4\n".data(using: .utf8)!.base64EncodedString() + pdf.base64EncodedString()
        let json = "{\"content\":\"\(base64)\",\"count\":1}"
        let abbreviated = JSONFormatting.abbreviatingBase64Strings(json)
        XCTAssertLessThan(abbreviated.count, 500)
        XCTAssertTrue(abbreviated.contains("<base64 PDF data:"))
        let object = try JSONSerialization.jsonObject(with: Data(abbreviated.utf8)) as? [String: Any]
        XCTAssertEqual(object?["count"] as? Int, 1)
        XCTAssertNotNil(JSONFormatting.prettyPrinted(abbreviated))
    }

    func testDoesNotTouchOrdinaryLongStrings() {
        let json = "{\"text\":\"\(String(repeating: "a", count: 2000))\"}"
        XCTAssertEqual(JSONFormatting.abbreviatingBase64Strings(json), json)
    }
}
