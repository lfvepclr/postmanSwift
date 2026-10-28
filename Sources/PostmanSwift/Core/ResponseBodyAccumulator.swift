import Foundation

/// Accumulates a response body, spilling to a temporary file once the in-memory budget is
/// exceeded. Used off the main thread by the HTTP transports; single-threaded by design.
final class ResponseBodyAccumulator {
    private let threshold: Int
    private let directory: URL
    private var buffer = Data()
    private var handle: FileHandle?
    private(set) var fileURL: URL?
    private(set) var byteCount = 0

    init(threshold: Int, directory: URL) {
        self.threshold = max(1, threshold)
        self.directory = directory
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        byteCount += chunk.count
        if handle == nil, byteCount > threshold {
            beginSpill()
        }
        if let handle {
            try? handle.write(contentsOf: chunk)
        } else {
            buffer.append(chunk)
        }
    }

    private func beginSpill() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("http-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let created = try? FileHandle(forWritingTo: url) else { return }
        handle = created
        fileURL = url
        if !buffer.isEmpty {
            try? created.write(contentsOf: buffer)
            buffer = Data()
        }
    }

    /// Ends accumulation. When the body was spilled, `data` is empty and `fileURL` points at it.
    func finish() -> (data: Data, fileURL: URL?, byteCount: Int) {
        try? handle?.close()
        handle = nil
        return (fileURL == nil ? buffer : Data(), fileURL, byteCount)
    }

    func discard() {
        try? handle?.close()
        handle = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        buffer = Data()
    }
}
