import Foundation
import SwiftUI
import Observation

enum RequestSection: String, CaseIterable, Identifiable {
    case params = "Params"
    case authorization = "Authorization"
    case headers = "Headers"
    case body = "Body"
    case preRequest = "Pre-request Script"
    case tests = "Tests"
    case settings = "Settings"

    var id: String { rawValue }
}

enum ResponseSection: String, CaseIterable, Identifiable {
    case headers = "Headers"
    case payload = "Payload"
    case preview = "Preview"
    case timing = "Timing"
    case cookies = "Cookies"
    case history = "执行记录"
    case visualizer = "Visualize"

    var id: String { rawValue }
}

enum BodyDisplayMode: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case raw = "Raw"

    var id: String { rawValue }
}

struct ResponseRecord {
    var result: HTTPResult
    var text: String?
    var pretty: String?
    var embeddedPDFs: [EmbeddedPDF] = []
    var tree: JSONTreePresentation?
    /// The request as actually sent, after variables, auth and cookies were applied.
    var prepared: PreparedRequest?
    /// Set when an inactive tab's heavy payload is released to keep memory bounded.
    var isEvicted = false
    /// Set when the raw body itself was written to disk. `result.body` is empty while this is set
    /// and `byteCount` still reports the original size.
    var spilledBodyURL: URL?
    var spilledByteCount = 0

    var byteCount: Int {
        spilledBodyURL == nil ? result.size : spilledByteCount
    }

    var estimatedBytes: Int {
        byteCount
            + (text?.utf8.count ?? 0)
            + (pretty?.utf8.count ?? 0)
            + (tree?.estimatedBytes ?? 0)
            + embeddedPDFs.reduce(0) { $0 + $1.data.count }
    }
}

@Observable
final class RequestTab: Identifiable {
    let id = UUID()
    let createdAt = Date()

    var draft: RequestDraft {
        didSet { sessionChangeHandler?() }
    }
    var response: ResponseRecord?
    var visualizerHTML: String?
    var isSending = false
    var isLoadingHistoryResponse = false
    var isRestoringResponse = false
    var requestSection: RequestSection = .params
    var responseSection: ResponseSection = .preview
    var displayMode: BodyDisplayMode = .preview
    var testResults: [TestResult] = []
    var console: [ConsoleEntry] = []
    var errorMessage: String?
    var codeLanguage: CodeLanguage = .curl
    var localVariables: [String: String] = [:]
    var savedSnapshot: RequestDraft? {
        didSet { sessionChangeHandler?() }
    }

    var collectionID: String?
    var itemID: String?
    var parentID: String?
    var isHistory: Bool
    /// Set by `AppStore`; replaces the old Combine `objectWillChange` subscription so session
    /// snapshots are still debounced without making every tab mutation publish globally.
    @ObservationIgnored var sessionChangeHandler: (() -> Void)?

    init(draft: RequestDraft, collectionID: String?, itemID: String?, saved: Bool, isHistory: Bool = false) {
        self.draft = draft
        self.collectionID = collectionID
        self.itemID = itemID
        self.isHistory = isHistory
        self.savedSnapshot = saved ? draft : nil
    }

    var title: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Request" : name
    }

    var isDirty: Bool {
        // History snapshots are read-only recreations, not edits waiting to be saved.
        if isHistory { return false }
        return savedSnapshot != draft
    }

    var statusSummary: String? {
        guard let response else { return nil }
        return "\(response.result.statusCode) \(response.result.statusText) · \(ContentUtilities.durationDescription(response.result.duration)) · \(ContentUtilities.sizeDescription(response.byteCount))"
    }
}
