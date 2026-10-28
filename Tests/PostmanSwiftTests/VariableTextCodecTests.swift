import XCTest
@testable import PostmanSwift

final class VariableTextCodecTests: XCTestCase {
    func testTextRoundTripsRows() {
        let rows = [
            KeyValue(key: "host", value: "https://api.example.com"),
            KeyValue(key: "token", value: "abc", disabled: true),
            KeyValue(key: "empty", value: "")
        ]
        let text = VariableTextCodec.text(from: rows)
        XCTAssertEqual(text, "host: https://api.example.com\n// token: abc\nempty: ")

        let parsed = VariableTextCodec.rows(from: text)
        XCTAssertEqual(parsed.map(\.key), ["host", "token", "empty"])
        XCTAssertEqual(parsed.map(\.value), ["https://api.example.com", "abc", ""])
        XCTAssertEqual(parsed.map(\.disabled), [false, true, false])
    }

    func testAcceptsEqualsSeparatorAndBareKeys() {
        let parsed = VariableTextCodec.rows(from: "a=1\n\n  b : 2  \nplain\n// disabled: yes")
        XCTAssertEqual(parsed.map(\.key), ["a", "b", "plain", "disabled"])
        XCTAssertEqual(parsed.map(\.value), ["1", "2", "", "yes"])
        XCTAssertEqual(parsed.map(\.disabled), [false, false, false, true])
    }

    func testColonInsideValueStaysInValue() {
        let parsed = VariableTextCodec.rows(from: "url: https://example.com:8443/path")
        XCTAssertEqual(parsed.first?.key, "url")
        XCTAssertEqual(parsed.first?.value, "https://example.com:8443/path")
    }

    func testEmptyPlaceholderRowsAreDropped() {
        XCTAssertEqual(VariableTextCodec.text(from: [KeyValue(), KeyValue(key: "a", value: "1")]), "a: 1")
        XCTAssertEqual(VariableTextCodec.rows(from: ":\na: 1").count, 1)
    }
}
