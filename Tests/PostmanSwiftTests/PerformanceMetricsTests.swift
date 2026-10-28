import XCTest
@testable import PostmanSwift

/// Records the hot flatten paths so regressions show up in `swift test` result bundles.
/// No hard thresholds: machines differ, the baseline lives in `.agent/perf-baseline`.
final class PerformanceMetricsTests: XCTestCase {
    private func largeRoot(items: Int) -> JSONTreeNode {
        let body = "[" + (0..<items).map { "{\"id\":\($0),\"name\":\"item \($0)\"}" }.joined(separator: ",") + "]"
        return JSONTreeParser.parse(body)!
    }

    func testFlattenExpandedLargeDocument() {
        let root = largeRoot(items: 4_000)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = JSONTreeFlattener.flatten(root, expanded: ["$"], embedded: [:])
        }
    }

    func testSubtreeFlattenSingleNode() {
        let root = largeRoot(items: 4_000)
        let full = JSONTreeFlattener.flattenResult(root, expanded: ["$"])
        let entry = full.index["$"]!
        measure(metrics: [XCTClockMetric()]) {
            _ = JSONTreeFlattener.subtreeResult(entry, expanded: ["$"], embedded: [:], sortKeys: false)
        }
    }
}
