import XCTest
import AppKit
@testable import PostmanSwift

@MainActor
final class TextKit2Tests: XCTestCase {
    /// Documents the root cause of the large-response hang: a TextKit 2 text view silently
    /// downgrades to TextKit 1 as soon as `layoutManager` is touched, which makes the estimated
    /// document height in `RawCodeTextView` pay for full layout passes on the main thread.
    func testAccessingLayoutManagerDowngradesTextKit2() {
        let textView = NSTextView(usingTextLayoutManager: true)
        XCTAssertNotNil(textView.textLayoutManager)
        _ = textView.layoutManager
        XCTAssertNil(textView.textLayoutManager)
        XCTAssertNotNil(textView.layoutManager)
    }
}
