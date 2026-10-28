import os

/// os_signpost wrapper for the performance baseline. The calls compile to a single enabled
/// check when Instruments is not recording, so hot paths can keep them.
enum PerformanceProbe {
    static let subsystem = "com.postmanswift.app"

    private static let log = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    private static let signposter = OSSignposter(logHandle: log)

    /// Measures a synchronous block and emits an interval signpost named `name`.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    static func event(_ name: StaticString) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(name)
    }

    static func event(_ name: StaticString, _ message: String) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(name, "\(message, privacy: .public)")
    }
}
