import XCTest
@testable import PostmanSwift

final class ListOrderingTests: XCTestCase {
    func testMoveDownLandsBeforeTarget() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(ListOrdering.moved(items, from: 0, to: 2), ["b", "a", "c", "d"])
    }

    func testMoveUpLandsBeforeTarget() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(ListOrdering.moved(items, from: 3, to: 1), ["a", "d", "b", "c"])
    }

    func testMoveToEnd() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(ListOrdering.moved(items, from: 0, to: 3), ["b", "c", "a"])
    }

    func testNoopAndOutOfBounds() {
        let items = ["a", "b"]
        XCTAssertEqual(ListOrdering.moved(items, from: 1, to: 1), items)
        XCTAssertEqual(ListOrdering.moved(items, from: 9, to: 0), items)
    }

    /// Mock lists translate a drop "after target" into `target + 1`.
    func testDropAfterTargetIndex() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(ListOrdering.moved(items, from: 0, to: 2), ["b", "a", "c"])
        XCTAssertEqual(ListOrdering.moved(items, from: 1, to: 3), ["a", "c", "b"])
    }

    func testMockServicesKeepIdentityAndFields() {
        var first = MockService(name: "one", prefix: "/one")
        first.cases = [MockCase(name: "c1")]
        var second = MockService(name: "two", prefix: "/two")
        second.cases = [MockCase(name: "c2")]
        let moved = ListOrdering.moved([first, second], from: 1, to: 0)
        XCTAssertEqual(moved.map(\.name), ["two", "one"])
        XCTAssertEqual(moved.map(\.id), [second.id, first.id])
        XCTAssertEqual(moved.first?.cases.map(\.name), ["c2"])
    }
}
