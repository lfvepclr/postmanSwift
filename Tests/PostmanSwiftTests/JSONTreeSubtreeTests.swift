import XCTest
@testable import PostmanSwift

final class JSONTreeSubtreeTests: XCTestCase {
    private func parse(_ json: String) -> JSONTreeNode {
        guard let root = JSONTreeParser.parse(json) else {
            XCTFail("failed to parse sample")
            return .null
        }
        return root
    }

    private func closeMatches(_ row: JSONTreeRow, open: JSONTreeRow) -> Bool {
        row.depth == open.depth && row.kind.isClosing
    }

    func testSubtreeResultMatchesFullFlattenSlice() {
        let root = parse(#"{"a":{"b":[1,2,{"c":"x"}]},"d":"text"}"#)
        let expanded: Set<String> = ["$", "$/a#0", "$/a#0/b#0", "$/a#0/b#0/[2]"]
        let full = JSONTreeFlattener.flattenResult(root, expanded: expanded)
        let entry = try! XCTUnwrap(full.index["$/a#0"])
        let subtree = JSONTreeFlattener.subtreeResult(
            entry,
            expanded: expanded,
            embedded: [:],
            sortKeys: false
        ).rows

        guard let start = full.rows.firstIndex(where: { $0.id == "$/a#0" }) else {
            return XCTFail("open row missing")
        }
        var end = start + 1
        while end < full.rows.count, !closeMatches(full.rows[end], open: full.rows[start]) {
            end += 1
        }
        if end < full.rows.count { end += 1 }
        XCTAssertEqual(subtree.map(\.id), Array(full.rows[start..<end]).map(\.id))
    }

    func testCollapsedSubtreeIsSingleRow() {
        let root = parse(#"{"a":{"b":1}}"#)
        let full = JSONTreeFlattener.flattenResult(root, expanded: ["$"])
        let entry = try! XCTUnwrap(full.index["$/a#0"])
        let subtree = JSONTreeFlattener.subtreeResult(
            entry,
            expanded: ["$"],
            embedded: [:],
            sortKeys: false
        ).rows
        XCTAssertEqual(subtree.map(\.id), ["$/a#0"])
        XCTAssertFalse(subtree[0].isExpanded)
    }

    /// Mirrors the view's incremental expand/collapse; the final rows must equal a full flatten.
    func testIncrementalExpandMatchesFullFlat10() {
        let root = parse(#"{"a":{"b":[1,2,{"c":"x"}]},"d":"text","e":[{"f":true},{"g":null}]}"#)
        var expanded: Set<String> = []
        var result = JSONTreeFlattener.flattenResult(root, expanded: expanded)
        var rows = result.rows
        var index = result.index

        func expand(_ path: String) {
            guard let position = rows.firstIndex(where: { $0.id == path }),
                  let entry = index[path] else { return }
            expanded.insert(path)
            let next = JSONTreeFlattener.subtreeResult(
                entry,
                expanded: expanded,
                embedded: [:],
                sortKeys: false
            )
            rows[position] = next.rows[0]
            rows.insert(contentsOf: next.rows.dropFirst(), at: position + 1)
            index.merge(next.index) { _, new in new }
        }

        expand("$")
        for _ in 0..<12 {
            guard let nextPath = rows.first(where: { $0.isExpandable && !$0.isExpanded })?.path else { break }
            expand(nextPath)
        }

        let expected = JSONTreeFlattener.flatten(root, expanded: expanded)
        XCTAssertEqual(rows.map(\.id), expected.map(\.id))
        XCTAssertEqual(rows.map(\.depth), expected.map(\.depth))
        XCTAssertEqual(rows.map(\.comma), expected.map(\.comma))
    }

    func testIncrementalCollapseMatchesFullFlatten() {
        let root = parse(#"{"a":{"b":[1,2,{"c":"x"}]},"d":"text"}"#)
        let paths: Set<String> = ["$", "$/a#0", "$/a#0/b#0", "$/a#0/b#0/[2]"]
        var rows = JSONTreeFlattener.flattenResult(root, expanded: paths).rows
        var expanded = paths

        guard let position = rows.firstIndex(where: { $0.id == "$/a#0/b#0" }) else {
            return XCTFail("missing node")
        }
        let open = rows[position]
        expanded.remove(open.path)
        rows[position] = open.settingExpanded(false)
        var end = position + 1
        while end < rows.count, rows[end].depth > open.depth { end += 1 }
        if end < rows.count, closeMatches(rows[end], open: open) { end += 1 }
        if end > position + 1 { rows.removeSubrange((position + 1)..<end) }

        let expected = JSONTreeFlattener.flatten(root, expanded: expanded)
        XCTAssertEqual(rows.map(\.id), expected.map(\.id))
    }

    func testFlattenLargeDocumentRecordsIndexForContainersOnly() {
        let items = (0..<500).map { "{\"id\":\($0),\"name\":\"item \($0)\"}" }.joined(separator: ",")
        let root = parse("[\(items)]")
        let result = JSONTreeFlattener.flattenResult(root, expanded: ["$"])
        XCTAssertEqual(result.rows.count, 2 + 500)
        XCTAssertEqual(result.index.count, 1 + 500)
        XCTAssertNotNil(result.index["$"])
    }
}
