import XCTest
@testable import PostmanSwift

final class JSONTreeSortTests: XCTestCase {
    private func root(_ json: String) throws -> JSONTreeNode {
        guard let root = DocumentTreeBuilder.parseEmbedded(json, kind: .json) else {
            throw NSError(domain: "JSONTreeSortTests", code: 0)
        }
        return root
    }

    func testSortKeysOrdersObjectEntries() throws {
        let root = try root("{\"gamma\":1,\"alpha\":2,\"beta\":3}")
        let expanded = JSONTreeFlattener.defaultExpandedPaths(root)
        let rows = JSONTreeFlattener.flatten(root, expanded: expanded, sortKeys: true)
        XCTAssertEqual(rows.compactMap(\.key), ["alpha", "beta", "gamma"])
    }

    func testUnsortedKeepsOriginalOrder() throws {
        let root = try root("{\"gamma\":1,\"alpha\":2,\"beta\":3}")
        let expanded = JSONTreeFlattener.defaultExpandedPaths(root)
        let rows = JSONTreeFlattener.flatten(root, expanded: expanded)
        XCTAssertEqual(rows.compactMap(\.key), ["gamma", "alpha", "beta"])
    }

    func testSortingLeavesArrayOrderUntouched() throws {
        let root = try root("{\"items\":[\"z\",\"a\"]}")
        let expanded = JSONTreeFlattener.defaultExpandedPaths(root)
        let rows = JSONTreeFlattener.flatten(root, expanded: expanded, sortKeys: true)
        let strings = rows.compactMap { row -> String? in
            if case .string(let value, _, _) = row.kind { return value }
            return nil
        }
        XCTAssertEqual(strings, ["z", "a"])
    }
}
