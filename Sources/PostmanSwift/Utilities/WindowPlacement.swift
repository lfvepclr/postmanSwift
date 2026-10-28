import AppKit

enum WindowPlacement {
    /// Returns the frame the window should move to when it is mostly outside `visible`,
    /// or nil when it is already visible enough on that screen.
    static func placedFrame(for frame: NSRect, in visible: NSRect, minimumVisibleRatio: CGFloat = 0.6) -> NSRect? {
        guard visible.width > 200, visible.height > 200, frame.width > 0, frame.height > 0 else { return nil }
        let overlap = visible.intersection(frame)
        let visibleArea = overlap.isNull ? 0 : overlap.width * overlap.height
        guard visibleArea / (frame.width * frame.height) < minimumVisibleRatio else { return nil }
        let width = min(frame.width, visible.width - 80)
        let height = min(frame.height, visible.height - 80)
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }
}
