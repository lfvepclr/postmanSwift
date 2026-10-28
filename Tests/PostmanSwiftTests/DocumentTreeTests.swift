import XCTest
@testable import PostmanSwift

final class DocumentTreeTests: XCTestCase {
    private func jsonQuoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    private func pdfBase64(byteCount: Int = 400) -> String {
        let data = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x42, count: byteCount)
        return data.base64EncodedString()
    }

    func testPayloadClassification() {
        XCTAssertEqual(PayloadClassifier.classify(jpdf()), .base64PDF)
        XCTAssertEqual(
            PayloadClassifier.classify("data:image/png;base64," + String(repeating: "iVBORw0KGgo", count: 10)),
            .base64Image
        )
        XCTAssertEqual(PayloadClassifier.classify("  {\"a\":1}\n"), .json)
        XCTAssertEqual(PayloadClassifier.classify("  [1,2]"), .json)
        XCTAssertEqual(PayloadClassifier.classify("<?xml version=\"1.0\"?><root/>"), .xml)
        XCTAssertEqual(PayloadClassifier.classify("<response><ok>true</ok></response>"), .xml)
        XCTAssertEqual(PayloadClassifier.classify("https://example.com/a"), .url)
        XCTAssertEqual(PayloadClassifier.classify("just some text"), .text)
        XCTAssertEqual(PayloadClassifier.classify("<!doctype html><html></html>"), .text)
        XCTAssertEqual(PayloadClassifier.classify("\"quoted\""), .text)
    }

    private func jpdf() -> String {
        pdfBase64()
    }

    func testNestedJSONExpandsInline() throws {
        let outer = "{\"outer\":\(jsonQuoted("{\"inner\":1}")),\"tail\":true}"
        let root = try XCTUnwrap(JSONTreeParser.parse(outer))
        let presentation = JSONTreePresentation.make(root: root)

        var sawEmbedded = false
        var sawInnerNumber = false
        for row in presentation.rows {
            switch row.kind {
            case .embeddedJSON(_, _, _, let childCount, let expanded):
                sawEmbedded = true
                XCTAssertEqual(childCount, 1)
                XCTAssertTrue(expanded)
            case .number(let literal) where literal == "1":
                sawInnerNumber = true
            default:
                break
            }
        }
        XCTAssertTrue(sawEmbedded)
        XCTAssertTrue(sawInnerNumber)
    }

    func testXMLTreeExposesAttributesAndJSONChildren() throws {
        let xml = """
        <root id="7">
          <item>a</item>
          <json><![CDATA[{"k":2}]]></json>
        </root>
        """
        let built = try XCTUnwrap(DocumentTreeBuilder.build(text: xml, mime: "application/xml"))
        XCTAssertEqual(built.kind, .xml)
        let presentation = JSONTreePresentation.make(root: built.node, kind: .xml)

        var attributeNames: [String] = []
        var embeddedCount: Int?
        var sawInnerNumber = false
        for row in presentation.rows {
            switch row.kind {
            case .xmlAttribute(let name, _, _):
                attributeNames.append(name)
            case .embeddedJSON(_, _, _, let count, _):
                embeddedCount = count
            case .number(let literal) where literal == "2":
                sawInnerNumber = true
            default:
                break
            }
        }
        XCTAssertEqual(attributeNames, ["id"])
        XCTAssertEqual(embeddedCount, 1)
        XCTAssertTrue(sawInnerNumber)
    }

    func testXMLInsideJSONExpandsInline() throws {
        let xml = "<root><a>1</a></root>"
        let outer = "{\"payload\":\(jsonQuoted(xml))}"
        let root = try XCTUnwrap(JSONTreeParser.parse(outer))
        let presentation = JSONTreePresentation.make(root: root)

        var sawEmbeddedXML = false
        var sawElement = false
        for row in presentation.rows {
            switch row.kind {
            case .embeddedXML(_, _, _, let count, let expanded):
                sawEmbeddedXML = true
                XCTAssertEqual(count, 1)
                XCTAssertTrue(expanded)
            case .xmlOpen(let name, _, _, _) where name == "a":
                sawElement = true
            default:
                break
            }
        }
        XCTAssertTrue(sawEmbeddedXML)
        XCTAssertTrue(sawElement)
    }

    func testBase64PDFInsideNestedJSONBecomesMediaRow() throws {
        let inner = "{\"file\":\"\(pdfBase64())\"}"
        let outer = "{\"body\":\(jsonQuoted(inner))}"
        let root = try XCTUnwrap(JSONTreeParser.parse(outer))
        let presentation = JSONTreePresentation.make(root: root)

        let pdfRow = presentation.rows.first { row in
            if case .pdf(_, _, _, _) = row.kind { return true }
            return false
        }
        XCTAssertNotNil(pdfRow)
        if let pdfRow, case .pdf(_, let bytes, _, _) = pdfRow.kind {
            XCTAssertGreaterThan(bytes, 400)
        }
    }

    func testSerializerPreservesOrderNumbersAndAbbreviatesMedia() throws {
        let json = "{\"b\":1,\"a\":\"x\",\"n\":1.2500e+3,\"pdf\":\"\(pdfBase64())\"}"
        let built = try XCTUnwrap(DocumentTreeBuilder.build(text: json, mime: "application/json"))
        let pretty = try XCTUnwrap(DocumentSerializer.prettyJSON(root: built.node))

        let bRange = try XCTUnwrap(pretty.range(of: "\"b\""))
        let aRange = try XCTUnwrap(pretty.range(of: "\"a\""))
        XCTAssertLessThan(bRange.lowerBound, aRange.lowerBound)
        XCTAssertTrue(pretty.contains("1.2500e+3"))
        XCTAssertTrue(pretty.contains("<base64 PDF data:"))
        XCTAssertFalse(pretty.contains(pdfBase64()))
    }

    func testXMLSerializerKeepsStructure() throws {
        let xml = "<root a=\"1\"><item>x</item><empty/></root>"
        let node = try XCTUnwrap(XMLTreeParser.parse(xml))
        let pretty = try XCTUnwrap(DocumentSerializer.prettyXML(root: node))
        XCTAssertTrue(pretty.contains("<root a=\"1\">"))
        XCTAssertTrue(pretty.contains("  <item>x</item>"))
        XCTAssertTrue(pretty.contains("<empty/>"))
        XCTAssertTrue(pretty.contains("</root>"))
    }

    func testLongLineDetectionAndWrapping() {
        let longLine = String(repeating: "A", count: 3_000)
        XCTAssertTrue(DisplayText.hasVeryLongLine(longLine))
        XCTAssertFalse(DisplayText.hasVeryLongLine("short\nlines"))

        let wrapped = DisplayText.wrapVeryLongLines(longLine)
        XCTAssertGreaterThan(wrapped.filter { $0 == "\n" }.count, 10)

        let chinese = String(repeating: "中", count: 2_000)
        let wrappedChinese = DisplayText.wrapVeryLongLines(chinese)
        XCTAssertEqual(wrappedChinese.replacingOccurrences(of: "\n", with: ""), chinese)
    }

    func testInvalidXMLFallsBackToNoTree() {
        XCTAssertNil(DocumentTreeBuilder.build(text: "<root><unclosed>", mime: "application/xml"))
    }
}
