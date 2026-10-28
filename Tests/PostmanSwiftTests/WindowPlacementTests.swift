import XCTest
@testable import PostmanSwift

final class WindowPlacementTests: XCTestCase {
    private let builtIn = NSRect(x: 0, y: 0, width: 1728, height: 1084)

    func testWindowOnTargetScreenStaysPut() {
        let frame = NSRect(x: 314, y: 225, width: 1100, height: 700)
        XCTAssertNil(WindowPlacement.placedFrame(for: frame, in: builtIn))
    }

    func testWindowOnAnotherDisplayMovesToTargetCentered() {
        let frame = NSRect(x: 2041, y: 151, width: 1100, height: 700)
        let placed = WindowPlacement.placedFrame(for: frame, in: builtIn)
        XCTAssertEqual(placed?.size, frame.size)
        XCTAssertEqual(placed?.midX, builtIn.midX)
        XCTAssertEqual(placed?.midY, builtIn.midY)
    }

    func testPartiallyVisibleWindowIsRecentered() {
        let frame = NSRect(x: 1600, y: 100, width: 1100, height: 700)
        let placed = WindowPlacement.placedFrame(for: frame, in: builtIn)
        XCTAssertEqual(placed?.midX, builtIn.midX)
        XCTAssertEqual(placed?.width, 1100)
    }

    func testOversizedWindowIsClampedToVisibleArea() {
        let frame = NSRect(x: 0, y: 0, width: 2400, height: 1400)
        let placed = WindowPlacement.placedFrame(for: frame, in: builtIn)
        XCTAssertEqual(placed?.width, builtIn.width - 80)
        XCTAssertEqual(placed?.height, builtIn.height - 80)
        XCTAssertEqual(placed?.midX, builtIn.midX)
        XCTAssertEqual(placed?.midY, builtIn.midY)
    }

    func testDegenerateValuesAreIgnored() {
        XCTAssertNil(WindowPlacement.placedFrame(for: NSRect(x: 0, y: 0, width: 100, height: 100), in: .zero))
        XCTAssertNil(WindowPlacement.placedFrame(for: .zero, in: builtIn))
    }
}
