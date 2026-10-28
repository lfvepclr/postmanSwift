import XCTest
@testable import PostmanSwift

final class CollectionMoveTests: XCTestCase {
    private func request(_ name: String) -> CollectionItem {
        CollectionTree.newRequestItem(named: name)
    }

    private func folder(_ name: String, _ children: [CollectionItem] = []) -> CollectionItem {
        var item = CollectionTree.newFolderItem(named: name)
        item.item = children
        return item
    }

    private func names(_ items: [CollectionItem]) -> [String] {
        items.map(\.name)
    }

    func testReorderSiblingsBeforeTarget() {
        var items = [request("a"), request("b"), request("c")]
        let moved = CollectionTree.move(&items, itemID: items[2].id, toParentID: nil, beforeSiblingID: items[0].id)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items), ["c", "a", "b"])
    }

    func testMoveToEndWithNilSibling() {
        var items = [request("a"), request("b"), request("c")]
        let moved = CollectionTree.move(&items, itemID: items[0].id, toParentID: nil, beforeSiblingID: nil)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items), ["b", "c", "a"])
    }

    func testMoveIntoFolder() {
        var items = [folder("f", [request("x")]), request("a")]
        let moved = CollectionTree.move(&items, itemID: items[1].id, toParentID: items[0].id, beforeSiblingID: nil)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items), ["f"])
        XCTAssertEqual(names(items[0].item ?? []), ["x", "a"])
    }

    func testMoveOutOfFolderToRoot() {
        var items = [folder("f", [request("x"), request("y")]), request("a")]
        let folderID = items[0].id
        let moved = CollectionTree.move(&items, itemID: items[0].item![0].id, toParentID: nil, beforeSiblingID: items[1].id)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items), ["f", "x", "a"])
        XCTAssertEqual(names(items[0].item ?? []), ["y"])
        XCTAssertEqual(items[0].id, folderID)
    }

    func testMoveBetweenFolders() {
        var items = [folder("f1", [request("x")]), folder("f2", [request("y")])]
        let moved = CollectionTree.move(&items, itemID: items[0].item![0].id, toParentID: items[1].id, beforeSiblingID: items[1].item!.first!.id)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items[0].item ?? []), [])
        XCTAssertEqual(names(items[1].item ?? []), ["x", "y"])
    }

    func testRejectMoveIntoOwnDescendant() {
        var items = [folder("outer", [folder("inner", [request("x")])])]
        let outerID = items[0].id
        let innerID = items[0].item![0].id
        let moved = CollectionTree.move(&items, itemID: outerID, toParentID: innerID, beforeSiblingID: nil)
        XCTAssertFalse(moved)
        XCTAssertEqual(names(items), ["outer"])
        XCTAssertEqual(names(items[0].item ?? []), ["inner"])
        XCTAssertEqual(names(items[0].item![0].item ?? []), ["x"])
    }

    func testRejectMoveIntoSelf() {
        var items = [folder("f")]
        let moved = CollectionTree.move(&items, itemID: items[0].id, toParentID: items[0].id, beforeSiblingID: nil)
        XCTAssertFalse(moved)
        XCTAssertEqual(names(items), ["f"])
    }

    func testRejectUnknownTargetParent() {
        var items = [request("a")]
        let moved = CollectionTree.move(&items, itemID: items[0].id, toParentID: "missing", beforeSiblingID: nil)
        XCTAssertFalse(moved)
        XCTAssertEqual(names(items), ["a"])
    }

    func testMoveRequestIntoTargetThatIsARequestIsRejected() {
        var items = [request("a"), request("b")]
        let moved = CollectionTree.move(&items, itemID: items[0].id, toParentID: items[1].id, beforeSiblingID: nil)
        XCTAssertFalse(moved)
        XCTAssertEqual(names(items), ["a", "b"])
    }

    func testEmptiedFolderStaysAFolder() {
        var items = [folder("f", [request("x")])]
        let moved = CollectionTree.move(&items, itemID: items[0].item![0].id, toParentID: nil, beforeSiblingID: nil)
        XCTAssertTrue(moved)
        XCTAssertEqual(names(items), ["f", "x"])
        XCTAssertTrue(items[0].isFolder)
        XCTAssertEqual(items[0].item ?? [], [])
    }

    func testAlreadyLastIsNoop() {
        var items = [request("a"), request("b")]
        let moved = CollectionTree.move(&items, itemID: items[1].id, toParentID: nil, beforeSiblingID: nil)
        XCTAssertFalse(moved)
        XCTAssertEqual(names(items), ["a", "b"])
    }
}
