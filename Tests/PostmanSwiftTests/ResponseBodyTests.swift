import XCTest
@testable import PostmanSwift

final class ResponseBodyAccumulatorTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAccumulatorKeepsSmallBodiesInMemory() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accumulator = ResponseBodyAccumulator(threshold: 16, directory: directory)
        accumulator.append(Data("hello".utf8))
        accumulator.append(Data(" world".utf8))
        let result = accumulator.finish()
        XCTAssertNil(result.fileURL)
        XCTAssertEqual(result.byteCount, 11)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "hello world")
    }

    func testAccumulatorSpillsOversizedBodies() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accumulator = ResponseBodyAccumulator(threshold: 8, directory: directory)
        accumulator.append(Data("1234".utf8))
        accumulator.append(Data("5678".utf8))
        accumulator.append(Data("90ab".utf8))
        let result = accumulator.finish()
        XCTAssertEqual(result.byteCount, 12)
        XCTAssertTrue(result.data.isEmpty)
        let fileURL = try XCTUnwrap(result.fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("1234567890ab".utf8))
    }

    func testHTTPResultPrefixReadsSpilledFile() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("body.bin")
        try Data("abcdefghij".utf8).write(to: fileURL)
        let result = HTTPResult(
            statusCode: 200,
            statusText: "OK",
            headers: [],
            body: Data(),
            duration: 0,
            finalURL: URL(string: "https://example.com")!,
            mimeType: "text/plain",
            redirects: [],
            bodyFileURL: fileURL,
            byteCount: 10
        )
        XCTAssertEqual(result.size, 10)
        XCTAssertTrue(result.isBodyFileBacked)
        XCTAssertEqual(String(decoding: result.bodyPrefix(maxBytes: 4), as: UTF8.self), "abcd")
    }

    func testHTTPClientSpillsLargeResponsesToDisk() async throws {
        var service = MockService(name: "Large", prefix: "/large")
        var mockCase = MockCase(name: "big", method: "GET", path: "/body")
        mockCase.body = String(repeating: "a", count: 300_000)
        service.cases = [mockCase]

        let server = MockServer()
        let port = UInt16.random(in: 20000...42000)
        try server.start(port: port, services: [service])
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

        var settings = AppSettings()
        settings.maxInMemoryResponseBytes = 64 * 1_024
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = HTTPClient(settings: settings, cookieJar: nil, spillDirectory: directory)
        let request = PreparedRequest(
            method: "GET",
            url: URL(string: base + "/large/body")!,
            headers: [],
            body: nil
        )
        let result = try await client.send(request)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertTrue(result.isBodyFileBacked)
        XCTAssertEqual(result.size, 300_000)
        XCTAssertTrue(result.body.isEmpty)
        let fileURL = try XCTUnwrap(result.bodyFileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL).count, 300_000)
        XCTAssertFalse(result.bodyPrefix(maxBytes: 16).isEmpty)
    }
}
