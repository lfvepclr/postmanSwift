import XCTest
@testable import PostmanSwift

final class VariableTooltipTests: XCTestCase {
    func testScannerFindsTokensAndNames() {
        let tokens = VariableTokenScanner.tokens(in: "a={{host}}&b={{$timestamp}}&c={{  spaced  }}")
        XCTAssertEqual(tokens.map(\.name), ["host", "$timestamp", "  spaced  "])
        XCTAssertEqual(tokens.first?.range, NSRange(location: 2, length: 8))
    }

    func testScannerIgnoresBrokenTokens() {
        XCTAssertTrue(VariableTokenScanner.tokens(in: "{{unclosed and {{ok}}").map(\.name).contains("ok"))
        XCTAssertTrue(VariableTokenScanner.tokens(in: "plain text").isEmpty)
    }

    func testTokenLookupAtCaretIndex() {
        let text = "x{{host}}y"
        XCTAssertEqual(VariableTokenScanner.token(in: text, at: 3)?.name, "host")
        XCTAssertNil(VariableTokenScanner.token(in: text, at: 9))
    }

    func testLookupClassifiesKnownDynamicAndMissing() {
        let lookup = VariableLookup(suggestions: [
            VariableSuggestion(name: "host", value: "api.example.com", scope: "Environment · QA", note: "接口地址")
        ])
        if case .variable(let scope, let value, let note) = lookup.info(for: "host").kind {
            XCTAssertEqual(scope, "Environment · QA")
            XCTAssertEqual(value, "api.example.com")
            XCTAssertEqual(note, "接口地址")
        } else {
            XCTFail("host should resolve as an environment variable")
        }
        if case .dynamic(let dynamic) = lookup.info(for: "$timestamp").kind {
            XCTAssertEqual(dynamic.name, "$timestamp")
        } else {
            XCTFail("$timestamp should resolve as a dynamic variable")
        }
        XCTAssertTrue(lookup.info(for: "missing").isUnknown)
        XCTAssertTrue(lookup.knownNames.contains("host"))
        XCTAssertTrue(lookup.knownNames.contains("$guid"))
    }

    func testHitTestUsesFontMetrics() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = "{{host}}"
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(VariableTokenScanner.hit(atX: width / 2, text: text, font: font)?.token.name, "host")
        XCTAssertNil(VariableTokenScanner.hit(atX: width + 20, text: text, font: font))
    }
}
