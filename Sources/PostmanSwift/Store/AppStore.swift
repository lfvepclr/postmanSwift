import Foundation
import SwiftUI
import Combine
import AppKit
import Observation

enum SidebarMode: String, CaseIterable, Identifiable {
    case collections = "Collections"
    case history = "History"
    case mock = "Mock API"

    var id: String { rawValue }
}

enum WorkspaceKind {
    case requests
    case mock
    case environments
}


struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var draft: RequestDraft
        var collectionID: String?
        var itemID: String?
        var parentID: String?
        var savedDraft: RequestDraft?
        var isHistory: Bool?
    }

    var tabs: [Tab]
    var activeIndex: Int?
}

struct RunnerResult: Identifiable {    var id = UUID()
    var name: String
    var iteration: Int
    var method: String
    var url: String
    var statusCode: Int?
    var duration: Double
    var tests: [TestResult] = []
    var error: String?

    var passed: Bool {
        error == nil && tests.allSatisfy(\.passed) && (statusCode ?? 0) > 0
    }
}

final class RunnerState: ObservableObject {
    @Published var selectedCollectionID: String?
    @Published var iterations = 1
    @Published var delayMilliseconds = 0
    @Published var dataRows: [[String: String]] = []
    @Published var dataFileName: String?
    @Published var results: [RunnerResult] = []
    @Published var isRunning = false
    @Published var stopRequested = false
    @Published var currentRequestName: String?
}

struct SendOutput {
    var prepared: PreparedRequest?
    var result: HTTPResult?
    var responseText: String?
    var responsePretty: String?
    var responseTree: JSONTreePresentation?
    var tests: [TestResult] = []
    var mutations: [VariableMutation] = []
    var console: [ConsoleEntry] = []
    var error: String?
    var visualizerTemplate: String?
    var visualizerData: String?
    var nextRequest: String?
    var embeddedPDFs: [EmbeddedPDF] = []
    var context: VariableContext
}

struct HistoryResponsePayload {
    var text: String?
    var pretty: String?
    var pdfs: [EmbeddedPDF]
    var tree: JSONTreePresentation?
}

struct PendingTabClose: Identifiable {
    let id = UUID()
    var tabIDs: [UUID]
    var dirtyCount: Int
    var unsavableCount: Int
    var singleTitle: String?
}

/// Purely presentational state (sheets, alerts, overlays). It is deliberately kept out of
/// `AppStore`: the store is observed by nearly every view, so flipping a sheet flag there used to
/// invalidate the sidebar, the tab bar and the whole response pane. Only views that actually show
/// this state observe `UIState`.
@MainActor
final class UIState: ObservableObject {
    @Published var showSettings = false
    @Published var showRunner = false
    @Published var showConsole = false
    @Published var showCookies = false
    @Published var showWebSocket = false
    @Published var showImportPanel = false
    @Published var alertMessage: String?
    @Published var pendingTabClose: PendingTabClose?
    @Published var codeSnippetTabID: UUID?
    @Published var cookieRevision = 0
}

@Observable
@MainActor
final class AppStore {
    static let shared = AppStore()

    var library = Library()
    var tabs: [RequestTab] = []
    var activeTabID: UUID? {
        didSet {
            guard activeTabID != oldValue else { return }
            selectedItemID = activeTab?.itemID
            scheduleSessionSave()
            enforceResponseBudget()
            if let tab = activeTab { restoreResponseIfNeeded(tab) }
        }
    }
    var history: [HistoryEntry] = []
    private(set) var historyDisplay: [String: HistoryRowDisplay] = [:]
    var console: [ConsoleEntry] = []
    var sidebarMode: SidebarMode = .collections
    var workspace: WorkspaceKind = .requests
    var selectedItemID: String?
    let runner = RunnerState()
    var selectedMockServiceID: String?
    var selectedMockCaseID: String?

    /// Sheet / alert / overlay flags live in their own observable object so toggling them does not
    /// publish a change on the store itself.
    let ui = UIState()

    let cookieJar = CookieJar()
    let mockServer = MockServer()
    let dataDirectory: URL
    private let libraryURL: URL
    private let cookieURL: URL
    private let historyStore: HistoryStore
    private let sessionURL: URL
    private let spillDirectory: URL
    private var responseCacheDirectory: URL {
        dataDirectory.appendingPathComponent("response-cache", isDirectory: true)
    }
    private var saveWorkItem: DispatchWorkItem?
    private var sessionSaveWorkItem: DispatchWorkItem?
    private var mockSyncWorkItem: DispatchWorkItem?
    private let persistenceQueue = DispatchQueue(label: "com.postmanswift.library-persist", qos: .utility)
    /// Session snapshots can contain multi-megabyte drafts. Encoding and writing them on the main
    /// thread stalled typing and tab switches, so the work runs on a serial utility queue.
    private let sessionQueue = DispatchQueue(label: "com.postmanswift.session-persist", qos: .utility)
    /// The history filter currently applied. Owned by the sidebar (local `@State` + debounce),
    /// remembered here so background refreshes keep the list the user is looking at.
    private var appliedHistorySearch: String?
    private var historyGeneration = 0
    private var deferredWorkStarted = false

    private init() {
        let override = ProcessInfo.processInfo.environment["POSTMANSWIFT_DATA_DIR"]
        let base: URL
        if let override, !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PostmanSwift", isDirectory: true)
            Self.migrateLegacyDataDirectory(to: base)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dataDirectory = base
        libraryURL = base.appendingPathComponent("library.json")
        cookieURL = base.appendingPathComponent("cookies.json")
        sessionURL = base.appendingPathComponent("session.json")
        spillDirectory = base.appendingPathComponent("session-cache", isDirectory: true)
        historyStore = HistoryStore(path: base.appendingPathComponent("history.sqlite").path)

        try? FileManager.default.createDirectory(at: spillDirectory, withIntermediateDirectories: true)
        // Spilled bodies are keyed by tab id and tab ids are regenerated on launch, so anything
        // left from a previous run can never be restored.
        if let stale = try? FileManager.default.contentsOfDirectory(at: spillDirectory, includingPropertiesForKeys: nil) {
            for url in stale {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let responseCache = base.appendingPathComponent("response-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: responseCache, withIntermediateDirectories: true)
        if let stale = try? FileManager.default.contentsOfDirectory(at: responseCache, includingPropertiesForKeys: nil) {
            for url in stale {
                try? FileManager.default.removeItem(at: url)
            }
        }

        loadLibrary()
        loadCookies()
        if library.collections.isEmpty {
            seedLibrary()
        }
        if library.activeEnvironmentID == nil {
            library.activeEnvironmentID = library.environments.first?.id
        }
        if !library.mockDefaultsSeeded {
            library.mockServices = MockDefaults.services()
            library.mockDefaultsSeeded = true
            persist()
        }
        loadSession()
    }

    /// Runs work that is not needed for the first frame: today that is the history list, which
    /// uses SQLite and a relative-date formatter for up to 400 rows.
    func startDeferredWork() {
        guard !deferredWorkStarted else { return }
        deferredWorkStarted = true
        reloadHistory()
    }

    /// The app used to store its data under "PostmanNative". Move that directory once so an
    /// existing library and history survive the rename instead of starting empty.
    private static func migrateLegacyDataDirectory(to base: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: base.path) else { return }
        let legacy = base.deletingLastPathComponent()
            .appendingPathComponent("PostmanNative", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: base)
        } catch {
            try? fm.copyItem(at: legacy, to: base)
        }
    }

    // MARK: - Derived state

    var activeTab: RequestTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var activeEnvironment: PMEnvironment? {
        guard let id = library.activeEnvironmentID else { return nil }
        return library.environments.first { $0.id == id }
    }

    var activeEnvironmentName: String {
        activeEnvironment?.name ?? "No Environment"
    }

    func collection(id: String) -> PMCollection? {
        library.collections.first { $0.id == id }
    }

    func collectionIndex(id: String) -> Int? {
        library.collections.firstIndex { $0.id == id }
    }

    func context(for tab: RequestTab, data: [String: String] = [:]) -> VariableContext {
        var context = VariableContext()
        context.globals = dictionary(from: library.globals)
        context.environment = dictionary(from: activeEnvironment?.values ?? [])
        if let cid = tab.collectionID, let collection = collection(id: cid) {
            context.collection = dictionary(from: collection.variable ?? [])
        }
        context.data = data
        context.local = tab.localVariables
        return context
    }

    func effectiveAuth(for tab: RequestTab) -> Auth {
        if let cid = tab.collectionID, let collection = collection(id: cid), let itemID = tab.itemID {
            let inherited = CollectionTree.effectiveAuth(collection: collection, itemID: itemID)
            return tab.draft.auth.isInherit ? inherited : tab.draft.auth
        }
        if tab.draft.auth.isInherit {
            if let cid = tab.collectionID, let collection = collection(id: cid) {
                return collection.auth ?? .none
            }
            return .none
        }
        return tab.draft.auth
    }

    private func dictionary(from values: [KeyValue]) -> [String: String] {
        values.reduce(into: [:]) { result, row in
            if row.isEnabled && !row.key.isEmpty { result[row.key] = row.value }
        }
    }

    // MARK: - Persistence

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        do {
            library = try JSONDecoder().decode(Library.self, from: data)
        } catch {
            let backup = libraryURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: libraryURL, to: backup)
        }
    }

    private func loadCookies() {
        guard let data = try? Data(contentsOf: cookieURL),
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        cookieJar.load(stored)
    }

    private func seedLibrary() {
        var request = RequestDef(method: "GET", url: "{{baseUrl}}/get")
        request.header = [KeyValue(key: "Accept", value: "application/json")]
        let item = CollectionItem(name: "Echo GET", request: request)
        var collection = PMCollection(name: "My Collection", items: [item])
        collection.variable = [KeyValue(key: "collectionName", value: "My Collection")]
        let environment = PMEnvironment(
            name: "Local",
            values: [KeyValue(key: "baseUrl", value: "https://postman-echo.com")]
        )
        library.collections = [collection]
        library.environments = [environment]
        library.activeEnvironmentID = environment.id
        persist()
    }

    func persist() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enqueueLibraryWrite(library: self.library, cookies: self.cookieJar.cookies)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func persistNow() {
        persistSession(synchronously: true)
        saveWorkItem?.cancel()
        let library = self.library
        let cookies = cookieJar.cookies
        let libraryURL = self.libraryURL
        let cookieURL = self.cookieURL
        persistenceQueue.sync {
            Self.write(library: library, cookies: cookies, libraryURL: libraryURL, cookieURL: cookieURL)
        }
    }

    /// Encoding a multi-megabyte library with `.prettyPrinted` blocks the main thread long enough to
    /// look like a hang, so snapshots are written on a serial background queue.
    private func enqueueLibraryWrite(library: Library, cookies: [StoredCookie]) {
        let libraryURL = self.libraryURL
        let cookieURL = self.cookieURL
        persistenceQueue.async {
            Self.write(library: library, cookies: cookies, libraryURL: libraryURL, cookieURL: cookieURL)
        }
    }

    private nonisolated static func write(library: Library, cookies: [StoredCookie], libraryURL: URL, cookieURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(library) {
            try? data.write(to: libraryURL, options: .atomic)
        }
        if let cookieData = try? encoder.encode(cookies) {
            try? cookieData.write(to: cookieURL, options: .atomic)
        }
    }

    // MARK: - Session restore

    private func observe(_ tab: RequestTab) {
        tab.sessionChangeHandler = { [weak self] in
            self?.scheduleSessionSave()
        }
    }

    private func scheduleSessionSave() {
        sessionSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistSession()
        }
        sessionSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func persistSession(synchronously: Bool = false) {
        let snapshots = tabs.map { tab in
            SessionSnapshot.Tab(
                draft: tab.draft,
                collectionID: tab.collectionID,
                itemID: tab.itemID,
                parentID: tab.parentID,
                savedDraft: tab.savedSnapshot,
                isHistory: tab.isHistory
            )
        }
        let activeIndex = activeTabID.flatMap { id in tabs.firstIndex(where: { $0.id == id }) }
        let snapshot = SessionSnapshot(tabs: snapshots, activeIndex: activeIndex)
        let url = sessionURL
        if synchronously {
            sessionQueue.sync {
                Self.writeSession(snapshot, to: url)
            }
        } else {
            sessionQueue.async {
                Self.writeSession(snapshot, to: url)
            }
        }
    }

    private nonisolated static func writeSession(_ snapshot: SessionSnapshot, to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return }
        for saved in snapshot.tabs {
            let tab = RequestTab(
                draft: saved.draft,
                collectionID: saved.collectionID,
                itemID: saved.itemID,
                saved: saved.savedDraft != nil,
                isHistory: saved.isHistory ?? false
            )
            tab.parentID = saved.parentID
            tab.savedSnapshot = saved.savedDraft
            tabs.append(tab)
            observe(tab)
        }
        if let index = snapshot.activeIndex, tabs.indices.contains(index) {
            activeTabID = tabs[index].id
        } else {
            activeTabID = tabs.first?.id
        }
        // Collection tabs come back without their response; hydrate the last one from history.
        for tab in tabs {
            if let itemID = tab.itemID {
                restoreLastResponse(for: tab, itemID: itemID)
            }
        }
    }

    /// Refetches history, optionally restricted to `search`. Passing nil (the default) clears the
    /// filter. The applied term is remembered so `reloadHistory()` (used after a send) keeps the
    /// list the sidebar is currently showing.
    func refreshHistory(search: String? = nil) {
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appliedHistorySearch = trimmed.isEmpty ? nil : trimmed
        reloadHistory()
    }

    private func reloadHistory() {
        historyGeneration &+= 1
        let generation = historyGeneration
        let search = appliedHistorySearch
        let store = historyStore
        PerformanceProbe.event("historyReload")
        Task.detached(priority: .userInitiated) {
            let entries = PerformanceProbe.measure("historyFetch") {
                store.fetch(limit: 400, search: search)
            }
            let display = Self.makeHistoryDisplay(entries)
            await MainActor.run { [weak self] in
                guard let self, generation == self.historyGeneration else { return }
                self.history = entries
                self.historyDisplay = display
            }
        }
    }

    private nonisolated static func makeHistoryDisplay(_ entries: [HistoryEntry]) -> [String: HistoryRowDisplay] {
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        var result: [String: HistoryRowDisplay] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            result[entry.id] = HistoryRowDisplay(
                id: entry.id,
                timestamp: entry.timestamp,
                method: entry.method,
                url: entry.url,
                statusCode: entry.statusCode,
                timeText: formatter.localizedString(for: entry.timestamp, relativeTo: now),
                requestName: entry.requestName,
                sizeText: ContentUtilities.sizeDescription(entry.responseSize),
                durationText: ContentUtilities.durationDescription(entry.duration)
            )
        }
        return result
    }

    /// Recent executions for one collection request, summaries only.
    func recentHistory(itemID: String, limit: Int = 25) -> [HistoryEntry] {
        historyStore.fetch(itemID: itemID, limit: limit)
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        historyDisplay = [:]
    }

    func deleteCookie(_ cookie: StoredCookie) {
        cookieJar.delete(cookie)
        ui.cookieRevision += 1
        persistNow()
    }

    func clearCookies() {
        cookieJar.clear()
        ui.cookieRevision += 1
        persistNow()
    }

    // MARK: - Tabs

    func openRequest(collectionID: String, item: CollectionItem) {
        workspace = .requests
        if let existing = tabs.first(where: { $0.itemID == item.id && $0.collectionID == collectionID }) {
            activeTabID = existing.id
            selectedItemID = item.id
            if existing.response == nil {
                restoreLastResponse(for: existing, itemID: item.id)
            }
            return
        }
        let draft = RequestDraft.make(from: item)
        let tab = RequestTab(draft: draft, collectionID: collectionID, itemID: item.id, saved: true)
        tabs.append(tab)
        observe(tab)
        activeTabID = tab.id
        selectedItemID = item.id
        scheduleSessionSave()
        restoreLastResponse(for: tab, itemID: item.id)
    }

    /// Reopens a collection request with the response it last received, including across launches.
    private func restoreLastResponse(for tab: RequestTab, itemID: String) {
        let store = historyStore
        Task.detached(priority: .userInitiated) {
            guard let entry = store.latestDetail(itemID: itemID),
                  let payload = Self.prepareHistoryPayload(entry) else { return }
            await MainActor.run {
                guard self.tabs.contains(where: { $0.id == tab.id }), tab.response == nil else { return }
                self.installHistoryResponse(entry, payload: payload, to: tab)
            }
        }
    }

    func openHistory(_ entry: HistoryEntry) {
        workspace = .requests
        let initialDraft = historyDraft(from: entry)
        let tab = RequestTab(draft: initialDraft, collectionID: entry.collectionID, itemID: nil, saved: false, isHistory: true)
        tabs.append(tab)
        observe(tab)
        activeTabID = tab.id
        scheduleSessionSave()

        guard entry.statusCode > 0 else { return }
        if !entry.isSummary {
            if let payload = Self.prepareHistoryPayload(entry) {
                installHistoryResponse(entry, payload: payload, to: tab)
            }
            return
        }

        // Only summary columns are in memory here. Load the multi-megabyte body, pretty-print it and
        // pull out embedded PDFs on a background thread so the click stays instant.
        tab.isLoadingHistoryResponse = true
        let history = historyStore
        Task.detached(priority: .userInitiated) { [weak self] in
            let detail = history.fetchDetail(id: entry.id)
            let payload = detail.flatMap { Self.prepareHistoryPayload($0) }
            await MainActor.run { [weak self] in
                guard let self, self.tabs.contains(where: { $0 === tab }) else { return }
                tab.isLoadingHistoryResponse = false
                guard let detail, let payload else { return }
                if tab.draft == initialDraft {
                    tab.draft = self.historyDraft(from: detail)
                }
                self.installHistoryResponse(detail, payload: payload, to: tab)
            }
        }
    }

    private func historyDraft(from entry: HistoryEntry) -> RequestDraft {
        var request = entry.request
        if request.method == nil { request.method = entry.method }
        if request.url == nil || request.url?.raw.isEmpty == true {
            request.url = URLDef(raw: entry.url)
        }
        let name = entry.requestName ?? "History Request"
        let item = CollectionItem(name: name, request: request)
        return RequestDraft.make(from: item)
    }

    private func installHistoryResponse(_ entry: HistoryEntry, payload: HistoryResponsePayload, to tab: RequestTab) {
        guard let finalURL = URL(string: entry.url) else { return }
        let body = entry.responseBody ?? entry.responseText.map { Data($0.utf8) } ?? Data()
        let result = HTTPResult(
            statusCode: entry.statusCode,
            statusText: HTTPClient.reason(for: entry.statusCode),
            headers: entry.responseHeaders,
            body: body,
            duration: entry.duration,
            finalURL: finalURL,
            mimeType: entry.mimeType,
            redirects: [],
            timings: entry.timings
        )
        discardResponseFiles(for: tab)
        tab.response = ResponseRecord(
            result: result,
            text: payload.text,
            pretty: payload.pretty,
            embeddedPDFs: payload.pdfs,
            tree: payload.tree,
            prepared: entry.resolvedRequest.map {
                PreparedRequest(
                    method: $0.method,
                    url: URL(string: $0.url) ?? finalURL,
                    headers: $0.headers,
                    body: $0.body
                )
            }
        )
        tab.displayMode = .preview
        // Keep the response pane where the user was; restoring a body should not jump to another tab.
        enforceResponseBudget()
    }

    nonisolated private static func prepareHistoryPayload(_ entry: HistoryEntry) -> HistoryResponsePayload? {
        let body = entry.responseBody ?? entry.responseText.map { Data($0.utf8) } ?? Data()
        let text = entry.responseText ?? ContentUtilities.decodeText(body, mime: entry.mimeType)
        let tree = documentTree(text: text, mime: entry.mimeType)
        return HistoryResponsePayload(
            text: text,
            pretty: nil,
            pdfs: tree == nil ? PDFExtractor.extract(text: text, mime: entry.mimeType, body: body) : [],
            tree: tree
        )
    }

    func newRequest(collectionID: String?, parentID: String?) {
        workspace = .requests
        var draft = RequestDraft()
        draft.name = "Untitled Request"
        let tab = RequestTab(draft: draft, collectionID: collectionID, itemID: nil, saved: false)
        tab.parentID = parentID
        tabs.append(tab)
        observe(tab)
        activeTabID = tab.id
        scheduleSessionSave()
    }

    func closeTab(_ tab: RequestTab) {
        close(tabs: [tab])
    }

    func requestClose(_ tab: RequestTab) {
        requestClose(tabs: [tab])
    }

    func requestCloseOthers(_ tab: RequestTab) {
        requestClose(tabs: tabs.filter { $0.id != tab.id })
    }

    func requestCloseTabsLeft(of tab: RequestTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), index > 0 else { return }
        requestClose(tabs: Array(tabs[..<index]))
    }

    func requestCloseTabsRight(of tab: RequestTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), index + 1 < tabs.count else { return }
        requestClose(tabs: Array(tabs[(index + 1)...]))
    }

    func requestCloseAll() {
        requestClose(tabs: tabs)
    }

    private func requestClose(tabs targets: [RequestTab]) {
        guard !targets.isEmpty else { return }
        let dirty = targets.filter(\.isDirty)
        guard !dirty.isEmpty else {
            close(tabs: targets)
            return
        }
        ui.pendingTabClose = PendingTabClose(
            tabIDs: targets.map(\.id),
            dirtyCount: dirty.count,
            unsavableCount: dirty.filter { $0.collectionID == nil }.count,
            singleTitle: dirty.count == 1 ? dirty[0].title : nil
        )
    }

    func confirmPendingClose(save: Bool) {
        guard let pending = ui.pendingTabClose else { return }
        ui.pendingTabClose = nil
        let targets = tabs.filter { pending.tabIDs.contains($0.id) }
        var closable: [RequestTab] = []
        var keptForManualSave = 0
        for tab in targets {
            if !save || !tab.isDirty {
                closable.append(tab)
            } else if tab.collectionID != nil {
                self.save(tab)
                closable.append(tab)
            } else {
                // A request that never belonged to a collection has no target to save into;
                // keep it open so the user can pick a collection instead of losing it.
                keptForManualSave += 1
            }
        }
        close(tabs: closable)
        if keptForManualSave > 0 {
            ui.alertMessage = "\(keptForManualSave) 个未归入集合的请求未关闭。请先在请求页选择集合保存，再关闭。"
        }
    }

    private func close(tabs targets: [RequestTab]) {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let activeIndex = activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
        for tab in targets {
            tab.sessionChangeHandler = nil
            discardResponseFiles(for: tab)
        }
        tabs.removeAll { ids.contains($0.id) }
        let activeClosed = activeTabID.map { ids.contains($0) } ?? false
        if activeClosed {
            if let index = activeIndex, tabs.indices.contains(index) {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
        scheduleSessionSave()
    }

    func save(_ tab: RequestTab) {
        guard let collectionID = tab.collectionID, let index = collectionIndex(id: collectionID) else {
            ui.alertMessage = "Choose a collection for this request before saving."
            return
        }
        if let itemID = tab.itemID,
           CollectionTree.find(library.collections[index].items, id: itemID) != nil {
            var items = library.collections[index].item ?? []
            CollectionTree.update(&items, id: itemID) { item in
                tab.draft.materialize(into: &item)
            }
            library.collections[index].item = items
        } else {
            var item = CollectionItem(name: tab.draft.name, request: RequestDef())
            tab.draft.materialize(into: &item)
            var items = library.collections[index].item ?? []
            CollectionTree.insert(item, into: &items, parentID: tab.parentID)
            library.collections[index].item = items
            tab.itemID = item.id
        }
        tab.savedSnapshot = tab.draft
        persist()
    }

    // MARK: - Collections

    func newCollection() {
        var collection = PMCollection(name: "New Collection")
        collection.info._postman_id = UUID().uuidString
        library.collections.append(collection)
        selectedItemID = nil
        persist()
    }

    func newFolder(collectionID: String, parentID: String?) {
        guard let index = collectionIndex(id: collectionID) else { return }
        let folder = CollectionTree.newFolderItem()
        var items = library.collections[index].item ?? []
        CollectionTree.insert(folder, into: &items, parentID: parentID)
        library.collections[index].item = items
        persist()
    }

    func createRequest(collectionID: String, parentID: String?) {
        guard let index = collectionIndex(id: collectionID) else { return }
        var item = CollectionTree.newRequestItem()
        item.name = "Untitled Request"
        var items = library.collections[index].item ?? []
        CollectionTree.insert(item, into: &items, parentID: parentID)
        library.collections[index].item = items
        persist()
        openRequest(collectionID: collectionID, item: item)
    }

    func rename(itemID: String, to name: String) {
        for index in library.collections.indices {
            var items = library.collections[index].item ?? []
            if CollectionTree.update(&items, id: itemID, transform: { $0.name = name }) {
                library.collections[index].item = items
                for tab in tabs where tab.itemID == itemID {
                    tab.draft.name = name
                    tab.savedSnapshot?.name = name
                }
                persist()
                return
            }
        }
    }

    func renameCollection(id: String, to name: String) {
        guard let index = collectionIndex(id: id) else { return }
        library.collections[index].info.name = name
        persist()
    }

    func delete(itemID: String) {
        for index in library.collections.indices {
            var items = library.collections[index].item ?? []
            if CollectionTree.remove(&items, id: itemID) != nil {
                library.collections[index].item = items
                for tab in tabs where tab.itemID == itemID {
                    tab.itemID = nil
                    tab.savedSnapshot = nil
                }
                if selectedItemID == itemID { selectedItemID = nil }
                persist()
                return
            }
        }
    }

    func deleteCollection(id: String) {
        library.collections.removeAll { $0.id == id }
        for tab in tabs where tab.collectionID == id {
            tab.collectionID = nil
            tab.itemID = nil
            tab.savedSnapshot = nil
        }
        persist()
    }

    func duplicate(itemID: String) {
        guard let found = locate(itemID: itemID) else { return }
        guard var copy = CollectionTree.find(found.collection.items, id: itemID) else { return }
        reidentify(&copy)
        copy.name += " copy"
        guard let index = collectionIndex(id: found.collection.id) else { return }
        var items = library.collections[index].item ?? []
        CollectionTree.insert(copy, into: &items, parentID: found.parentID)
        library.collections[index].item = items
        persist()
    }

    private func locate(itemID: String) -> (collection: PMCollection, parentID: String?)? {
        for collection in library.collections {
            if let chain = CollectionTree.path(to: itemID, in: collection.items) {
                let parent = chain.count > 1 ? chain[chain.count - 2].id : nil
                return (collection, parent)
            }
        }
        return nil
    }

    @discardableResult
    func moveItem(itemID: String, toParentID: String?, beforeSiblingID: String?) -> Bool {
        for index in library.collections.indices {
            var items = library.collections[index].item ?? []
            guard CollectionTree.find(items, id: itemID) != nil else { continue }
            guard CollectionTree.move(&items, itemID: itemID, toParentID: toParentID, beforeSiblingID: beforeSiblingID) else { return false }
            library.collections[index].item = items
            persist()
            return true
        }
        return false
    }

    private func reidentify(_ item: inout CollectionItem) {
        item.id = UUID().uuidString
        if var children = item.item {
            for index in children.indices {
                reidentify(&children[index])
            }
            item.item = children
        }
    }

    // MARK: - Sending

    func send(_ tab: RequestTab) {
        guard !tab.isSending else { return }
        let draft = tab.draft
        let context = context(for: tab)
        var settings = library.settings
        settings.followRedirects = draft.followRedirects
        settings.sslVerification = draft.strictSSL
        let auth = effectiveAuth(for: tab)
        let inheritedScripts: InheritedScripts = {
            guard let collectionID = tab.collectionID,
                  let collection = collection(id: collectionID),
                  let itemID = tab.itemID else { return InheritedScripts() }
            return CollectionTree.scripts(collection: collection, itemID: itemID)
        }()
        let collectionName = tab.collectionID.flatMap { collection(id: $0)?.info.name }
        let info = ScriptInfo(
            requestName: tab.title,
            requestID: tab.itemID ?? tab.id.uuidString,
            eventName: "test"
        )
        let cookies = cookieJar

        tab.isSending = true
        tab.errorMessage = nil
        tab.response = nil
        tab.testResults = []
        tab.console.removeAll()
        tab.responseSection = .preview

        Task {
            let output = await Self.performSend(
                draft: draft,
                auth: auth,
                context: context,
                settings: settings,
                cookies: cookies,
                info: info,
                inheritedPreRequest: inheritedScripts.preRequest,
                inheritedTests: inheritedScripts.tests,
                spillDirectory: responseCacheDirectory
            )
            tab.isSending = false
            tab.console = output.console
            appendConsole(output.console)
            apply(mutations: output.mutations, to: tab)

            if let error = output.error {
                tab.errorMessage = error
                let entry = ConsoleEntry(kind: .error, title: "Request failed", detail: error)
                tab.console.append(entry)
                console.append(entry)
                return
            }
            guard let result = output.result else { return }
            ui.cookieRevision += 1
            if result.usedLegacySocketFallback {
                let entry = ConsoleEntry(
                    kind: .script,
                    title: "Legacy HTTP fallback",
                    detail: "macOS 26 App Transport Security blocked URLSession for this http:// request, so it was retried through the native socket transport. HTTPS requests always use the system stack."
                )
                tab.console.append(entry)
                console.append(entry)
            }

            discardResponseFiles(for: tab)
            tab.response = ResponseRecord(
                result: result,
                text: output.responseText,
                pretty: output.responsePretty,
                embeddedPDFs: output.embeddedPDFs,
                tree: output.responseTree,
                prepared: output.prepared
            )
            tab.testResults = output.tests
            tab.displayMode = .preview
            enforceResponseBudget()
            if let template = output.visualizerTemplate {
                tab.visualizerHTML = VisualizerRenderer.html(template: template, dataJSON: output.visualizerData)
                tab.responseSection = .visualizer
            } else {
                tab.visualizerHTML = nil
            }

            if let prepared = output.prepared {
                let historyEntry = HistoryEntry(
                    method: prepared.method,
                    url: prepared.url.absoluteString,
                    statusCode: result.statusCode,
                    duration: result.duration,
                    responseSize: result.size,
                    collectionID: tab.collectionID,
                    collectionName: collectionName,
                    requestName: tab.title,
                    request: draft.asRequestDef(),
                    responseHeaders: result.headers,
                    responseBody: result.isBodyFileBacked ? nil : result.body,
                    responseText: output.responseText,
                    mimeType: result.mimeType,
                    itemID: tab.itemID,
                    resolvedRequest: output.prepared.map {
                        ResolvedRequest(
                            method: $0.method,
                            url: $0.url.absoluteString,
                            headers: $0.headers,
                            body: $0.body
                        )
                    },
                    timings: result.timings,
                    responseBodySourceURL: result.bodyFileURL
                )
                let store = historyStore
                Task.detached(priority: .utility) {
                    store.insert(historyEntry)
                    await MainActor.run { self.reloadHistory() }
                }
            }
            persist()
        }
    }

    func cancel(_ tab: RequestTab) {
        tab.isSending = false
    }

    nonisolated static func performSend(
        draft: RequestDraft,
        auth: Auth,
        context: VariableContext,
        settings: AppSettings,
        cookies: CookieJar,
        info: ScriptInfo,
        inheritedPreRequest: [String] = [],
        inheritedTests: [String] = [],
        spillDirectory: URL? = nil
    ) async -> SendOutput {
        var workingContext = context
        // One batch of dynamic values per request: every {{$timestamp}} / {{$guid}} in the
        // URL, params, headers, body and scripts of this send must resolve identically.
        workingContext.resetDynamicCache()
        var consoleEntries: [ConsoleEntry] = []
        let runner = ScriptRunner(settings: settings, cookieJar: cookies)

        var prepared: PreparedRequest
        do {
            prepared = try RequestBuilder.build(
                draft: draft,
                context: workingContext,
                settings: settings,
                cookies: cookies,
                auth: auth
            )
        } catch {
            return SendOutput(error: error.localizedDescription, context: workingContext)
        }

        consoleEntries.append(Self.requestConsoleEntry(prepared, body: prepared.body))

        var allMutations: [VariableMutation] = []
        let itemPre = draft.preRequestScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [draft.preRequestScript]
        let preScripts = inheritedPreRequest + itemPre
        if !preScripts.isEmpty {
            var lastMutation: RequestMutation?
            for source in preScripts {
                var preInfo = info
                preInfo.eventName = "prerequest"
                let outcome = runner.run(
                    source: source,
                    phase: .preRequest,
                    context: workingContext,
                    request: prepared,
                    response: nil,
                    info: preInfo
                )
                allMutations.append(contentsOf: outcome.mutations)
                apply(mutations: outcome.mutations, to: &workingContext)
                consoleEntries.append(contentsOf: outcome.console)
                if let mutation = outcome.requestMutation {
                    Self.apply(mutation, to: &prepared)
                    lastMutation = mutation
                }
                if let error = outcome.error {
                    consoleEntries.append(ConsoleEntry(kind: .error, title: "Pre-request script", detail: error))
                }
            }

            do {
                prepared = try RequestBuilder.build(
                    draft: draft,
                    context: workingContext,
                    settings: settings,
                    cookies: cookies,
                    auth: auth
                )
                if let lastMutation {
                    Self.apply(lastMutation, to: &prepared)
                }
            } catch {
                return SendOutput(prepared: prepared, mutations: allMutations, console: consoleEntries, error: error.localizedDescription, context: workingContext)
            }
        }

        let client = HTTPClient(settings: settings, cookieJar: cookies, spillDirectory: spillDirectory)
        let result: HTTPResult
        do {
            result = try await client.send(prepared)
        } catch {
            return SendOutput(prepared: prepared, mutations: allMutations, console: consoleEntries, error: error.localizedDescription, context: workingContext)
        }

        consoleEntries.append(Self.responseConsoleEntry(result))
        let displayLimit = max(1, min(settings.maxResponseDisplayBytes, 2_000_000))
        let text: String?
        if result.isBodyFileBacked {
            let prefix = result.bodyPrefix(maxBytes: displayLimit)
            let decoded = ContentUtilities.decodeText(prefix, mime: result.mimeType) ?? ""
            text = result.size > displayLimit
                ? decoded + "\n\n… 响应共 \(ContentUtilities.sizeDescription(result.size))，预览仅显示前 \(ContentUtilities.sizeDescription(displayLimit))。完整内容请使用 Save。"
                : decoded
        } else {
            text = result.text
        }
        let tree = Self.documentTree(text: text, mime: result.mimeType)
        let embeddedPDFs: [EmbeddedPDF]
        if result.isBodyFileBacked || tree != nil {
            embeddedPDFs = []
        } else {
            embeddedPDFs = PDFExtractor.extract(text: text, mime: result.mimeType, body: result.body)
        }

        var tests: [TestResult] = []
        var visualizerTemplate: String?
        var visualizerData: String?
        var nextRequest: String?
        let itemTests = draft.testScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [draft.testScript]
        let testScripts = itemTests + inheritedTests
        if !testScripts.isEmpty {
            for source in testScripts {
                let outcome = runner.run(
                    source: source,
                    phase: .test,
                    context: workingContext,
                    request: prepared,
                    response: result,
                    info: info
                )
                tests.append(contentsOf: outcome.tests)
                allMutations.append(contentsOf: outcome.mutations)
                apply(mutations: outcome.mutations, to: &workingContext)
                consoleEntries.append(contentsOf: outcome.console)
                if let template = outcome.visualizerTemplate {
                    visualizerTemplate = template
                    visualizerData = outcome.visualizerData
                }
                if let next = outcome.nextRequest { nextRequest = next }
                if let error = outcome.error {
                    consoleEntries.append(ConsoleEntry(kind: .error, title: "Tests", detail: error))
                }
            }
        }

        return SendOutput(
            prepared: prepared,
            result: result,
            responseText: text,
            responsePretty: nil,
            responseTree: tree,
            tests: tests,
            mutations: allMutations,
            console: consoleEntries,
            visualizerTemplate: visualizerTemplate,
            visualizerData: visualizerData,
            nextRequest: nextRequest,
            embeddedPDFs: embeddedPDFs,
            context: workingContext
        )
    }

    nonisolated static func apply(_ mutation: RequestMutation, to prepared: inout PreparedRequest) {
        if let method = mutation.method, !method.isEmpty {
            prepared.method = method.uppercased()
        }
        if let url = mutation.url, let parsed = URL(string: URLUtilities.normalize(url)) {
            prepared.url = parsed
        }
        if let headers = mutation.headers {
            prepared.headers = headers
        }
    }

    nonisolated private static func apply(mutations: [VariableMutation], to context: inout VariableContext) {
        for mutation in mutations {
            switch mutation.scope {
            case .environment:
                if mutation.clearAll { context.environment.removeAll() }
                else if let value = mutation.value { context.environment[mutation.key] = value }
                else { context.environment.removeValue(forKey: mutation.key) }
            case .globals:
                if mutation.clearAll { context.globals.removeAll() }
                else if let value = mutation.value { context.globals[mutation.key] = value }
                else { context.globals.removeValue(forKey: mutation.key) }
            case .collectionVariables:
                if mutation.clearAll { context.collection.removeAll() }
                else if let value = mutation.value { context.collection[mutation.key] = value }
                else { context.collection.removeValue(forKey: mutation.key) }
            case .variables:
                if mutation.clearAll { context.local.removeAll() }
                else if let value = mutation.value { context.local[mutation.key] = value }
                else { context.local.removeValue(forKey: mutation.key) }
            case .iterationData:
                if mutation.clearAll { context.data.removeAll() }
                else if let value = mutation.value { context.data[mutation.key] = value }
                else { context.data.removeValue(forKey: mutation.key) }
            }
        }
    }

    private func apply(mutations: [VariableMutation], to tab: RequestTab) {
        guard !mutations.isEmpty else { return }
        for mutation in mutations {
            switch mutation.scope {
            case .environment:
                guard let id = library.activeEnvironmentID,
                      let index = library.environments.firstIndex(where: { $0.id == id }) else { continue }
                updateValues(&library.environments[index].values, mutation: mutation)
            case .globals:
                updateValues(&library.globals, mutation: mutation)
            case .collectionVariables:
                guard let cid = tab.collectionID, let index = collectionIndex(id: cid) else { continue }
                var values = library.collections[index].variable ?? []
                updateValues(&values, mutation: mutation)
                library.collections[index].variable = values.isEmpty ? nil : values
            case .variables:
                if mutation.clearAll { tab.localVariables.removeAll() }
                else if let value = mutation.value { tab.localVariables[mutation.key] = value }
                else { tab.localVariables.removeValue(forKey: mutation.key) }
            case .iterationData:
                break
            }
        }
        persist()
    }

    private func updateValues(_ values: inout [KeyValue], mutation: VariableMutation) {
        if mutation.clearAll {
            values.removeAll()
            return
        }
        if let value = mutation.value {
            if let index = values.firstIndex(where: { $0.key == mutation.key }) {
                values[index].value = value
                values[index].disabled = false
            } else {
                values.append(KeyValue(key: mutation.key, value: value))
            }
        } else {
            values.removeAll { $0.key == mutation.key }
        }
    }

    private func appendConsole(_ entries: [ConsoleEntry]) {
        console.append(contentsOf: entries)
        if console.count > 500 {
            console.removeFirst(console.count - 500)
        }
    }

    nonisolated private static func requestConsoleEntry(_ request: PreparedRequest, body: Data?) -> ConsoleEntry {
        var detail = "\(request.method) \(request.url.absoluteString)"
        if !request.headers.isEmpty {
            detail += "\n" + request.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        if let body, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            detail += "\n\n" + text
        }
        return ConsoleEntry(kind: .request, title: "\(request.method) \(request.url.path)", detail: detail)
    }

    nonisolated private static func responseConsoleEntry(_ result: HTTPResult) -> ConsoleEntry {
        var detail = "\(result.statusCode) \(result.statusText) · \(ContentUtilities.durationDescription(result.duration)) · \(ContentUtilities.sizeDescription(result.size))"
        if !result.headers.isEmpty {
            detail += "\n" + result.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        return ConsoleEntry(kind: .response, title: "Response \(result.statusCode)", detail: detail)
    }

    nonisolated private static func documentTree(text: String?, mime: String?) -> JSONTreePresentation? {
        guard let text, !text.isEmpty else { return nil }
        guard let built = DocumentTreeBuilder.build(text: text, mime: mime) else { return nil }
        return JSONTreePresentation.make(root: built.node, kind: built.kind)
    }

    nonisolated private static func prettyBody(text: String?, mime: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        let lower = (mime ?? "").lowercased()
        let head = text.drop(while: isWhitespace).prefix(16)
        let isJSON = lower.contains("json") || head.hasPrefix("{") || head.hasPrefix("[")
        if isJSON {
            guard let built = DocumentTreeBuilder.build(text: text, mime: "application/json"),
                  built.kind == .json else { return text }
            return DocumentSerializer.prettyJSON(root: built.node) ?? text
        }
        if lower.contains("xml") || head.hasPrefix("<") {
            guard let node = XMLTreeParser.parse(text) else { return text }
            return DocumentSerializer.prettyXML(root: node) ?? text
        }
        return text
    }

    // MARK: - Code snippets

    func codeSnippet(for tab: RequestTab, language: CodeLanguage) -> String {
        let context = context(for: tab)
        if let prepared = try? RequestBuilder.build(
            draft: tab.draft,
            context: context,
            settings: library.settings,
            cookies: cookieJar,
            auth: effectiveAuth(for: tab)
        ) {
            return CodeGenerator.generate(prepared, language: language)
        }
        var fallback = PreparedRequest(
            method: tab.draft.method,
            url: URL(string: "https://example.com")!,
            headers: tab.draft.headers,
            body: tab.draft.rawBody.data(using: .utf8)
        )
        fallback.url = URL(string: URLUtilities.normalize(tab.draft.urlRaw)) ?? fallback.url
        return CodeGenerator.generate(fallback, language: language)
    }

    func openCodeSnippet(_ tab: RequestTab) {
        ui.codeSnippetTabID = tab.id
    }

    func closeCodeSnippet() {
        ui.codeSnippetTabID = nil
    }

    func openEnvironments() {
        sidebarMode = .collections
        workspace = .environments
    }

    func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        workspace = mode == .mock ? .mock : .requests
    }

    // MARK: - Response display payload

    private let responseHeavyThreshold = 256 * 1_024

    /// Keep at most two heavy payloads resident (the active tab plus the newest other tab).
    /// Everything else releases its decoded payloads and, when the raw body is itself large,
    /// spills the body to disk so memory does not grow with the number of open tabs.
    func enforceResponseBudget() {
        let heavy = tabs.filter { tab in
            guard let response = tab.response, !response.isEvicted else { return false }
            return response.estimatedBytes > responseHeavyThreshold
        }
        guard heavy.count > 1 else { return }

        let keepActive = activeTabID
        let otherNewest = heavy
            .filter { $0.id != keepActive }
            .max { $0.createdAt < $1.createdAt }?.id

        for tab in heavy where tab.id != keepActive && tab.id != otherNewest {
            evictResponse(tab)
        }
    }

    private func spillURL(for tabID: UUID) -> URL {
        spillDirectory.appendingPathComponent("response-\(tabID.uuidString).bin")
    }

    private func discardSpilledBody(for tabID: UUID) {
        try? FileManager.default.removeItem(at: spillURL(for: tabID))
    }

    private func discardResponseFiles(for tab: RequestTab) {
        if let url = tab.response?.result.bodyFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        discardSpilledBody(for: tab.id)
    }

    private func evictResponse(_ tab: RequestTab) {
        guard var response = tab.response else { return }
        var changed = false
        if !response.isEvicted {
            response.text = nil
            response.pretty = nil
            response.tree = nil
            response.embeddedPDFs = []
            response.isEvicted = true
            changed = true
        }

        if response.result.bodyFileURL == nil,
           response.spilledBodyURL == nil,
           response.result.body.count > responseHeavyThreshold {
            let body = response.result.body
            let url = spillURL(for: tab.id)
            Task.detached(priority: .utility) {
                guard (try? body.write(to: url, options: .atomic)) != nil else { return }
                await MainActor.run {
                    guard var current = tab.response,
                          current.spilledBodyURL == nil,
                          current.result.body.count == body.count else { return }
                    current.spilledBodyURL = url
                    current.spilledByteCount = body.count
                    current.result.body = Data()
                    tab.response = current
                }
            }
        }

        if changed {
            tab.response = response
        }
    }

    func restoreResponseIfNeeded(_ tab: RequestTab) {
        guard let response = tab.response, response.isEvicted, !tab.isRestoringResponse else { return }
        tab.isRestoringResponse = true
        let body = response.result.body
        let spillURL = response.spilledBodyURL
        let mime = response.result.mimeType
        Task.detached(priority: .userInitiated) {
            var resolved = body
            if resolved.isEmpty {
                if let spillURL, let stored = try? Data(contentsOf: spillURL) {
                    resolved = stored
                } else if response.result.isBodyFileBacked {
                    resolved = response.result.bodyPrefix(maxBytes: 2_000_000)
                }
            }
            var text = ContentUtilities.decodeText(resolved, mime: mime) ?? ""
            if response.result.isBodyFileBacked, response.result.size > 2_000_000 {
                text += "\n\n… 响应共 \(ContentUtilities.sizeDescription(response.result.size))，预览仅显示前 2 MB。完整内容请使用 Save。"
            }
            let tree = Self.documentTree(text: text, mime: mime)
            let restoredBody = resolved
            let restoredText = text
            await MainActor.run {
                tab.isRestoringResponse = false
                guard var current = tab.response, current.isEvicted else { return }
                if current.result.bodyFileURL == nil {
                    current.result.body = restoredBody
                }
                current.spilledBodyURL = nil
                current.spilledByteCount = 0
                current.text = restoredText
                current.tree = tree
                current.isEvicted = false
                tab.response = current
                self.enforceResponseBudget()
            }
        }
    }

    // MARK: - Environments

    func addEnvironment() {
        let environment = PMEnvironment(name: "New Environment")
        library.environments.append(environment)
        library.activeEnvironmentID = environment.id
        persist()
    }

    /// Reorders environments for drag-and-drop; the active environment id is unchanged.
    func moveEnvironment(id: String, to targetIndex: Int) {
        guard let source = library.environments.firstIndex(where: { $0.id == id }) else { return }
        let moved = ListOrdering.moved(library.environments, from: source, to: targetIndex)
        guard moved.map(\.id) != library.environments.map(\.id) else { return }
        library.environments = moved
        persist()
    }

    func deleteEnvironment(id: String) {
        library.environments.removeAll { $0.id == id }
        if library.activeEnvironmentID == id {
            library.activeEnvironmentID = library.environments.first?.id
        }
        persist()
    }

    func setActiveEnvironment(id: String?) {
        library.activeEnvironmentID = id
        persist()
    }

    func applyTheme() {
        switch library.settings.theme {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    func setTheme(_ theme: String) {
        guard library.settings.theme != theme else { return }
        library.settings.theme = theme
        applyTheme()
        persist()
    }

    func updateEnvironment(_ environment: PMEnvironment) {
        if let index = library.environments.firstIndex(where: { $0.id == environment.id }) {
            library.environments[index] = environment
            persist()
        }
    }

    func updateGlobals(_ globals: [KeyValue]) {
        library.globals = globals
        persist()
    }

    // MARK: - Mock API

    @discardableResult
    func addMockService() -> String {
        var service = MockService(name: "New Service", prefix: "/api")
        service.cases = [MockCase(name: "Success", method: "GET", path: "/ok")]
        library.mockServices.append(service)
        selectedMockServiceID = service.id
        selectedMockCaseID = service.cases.first?.id
        persist()
        syncMockServer()
        return service.id
    }

    func deleteMockService(id: String) {
        library.mockServices.removeAll { $0.id == id }
        ensureMockSelection()
        persist()
        syncMockServer()
    }

    var selectedMockService: MockService? {
        guard let id = selectedMockServiceID else { return nil }
        return library.mockServices.first { $0.id == id }
    }

    var selectedMockCase: MockCase? {
        guard let service = selectedMockService, let id = selectedMockCaseID else { return nil }
        return service.cases.first { $0.id == id }
    }

    func selectMockService(_ id: String?) {
        selectedMockServiceID = id
        selectedMockCaseID = library.mockServices.first { $0.id == id }?.cases.first?.id
    }

    func selectMockCase(_ id: String?) {
        selectedMockCaseID = id
    }

    func ensureMockSelection() {
        if selectedMockServiceID == nil || !library.mockServices.contains(where: { $0.id == selectedMockServiceID }) {
            selectedMockServiceID = library.mockServices.first?.id
        }
        if selectedMockCaseID == nil || selectedMockCase == nil {
            selectedMockCaseID = selectedMockService?.cases.first?.id
        }
    }

    func updateMockService(_ service: MockService) {
        guard let index = library.mockServices.firstIndex(where: { $0.id == service.id }) else { return }
        library.mockServices[index] = service
        persist()
        scheduleMockSync()
    }

    @discardableResult
    func addMockCase(serviceID: String) -> String? {
        guard let index = library.mockServices.firstIndex(where: { $0.id == serviceID }) else { return nil }
        var mockCase = MockCase(name: "New Case", method: "GET", path: "/new")
        mockCase.body = #"{"\n  \"ok\": true\n}"#
        library.mockServices[index].cases.append(mockCase)
        selectedMockServiceID = serviceID
        selectedMockCaseID = mockCase.id
        persist()
        syncMockServer()
        return mockCase.id
    }

    func deleteMockCase(serviceID: String, caseID: String) {
        guard let index = library.mockServices.firstIndex(where: { $0.id == serviceID }) else { return }
        library.mockServices[index].cases.removeAll { $0.id == caseID }
        ensureMockSelection()
        persist()
        syncMockServer()
    }

    func updateMockCase(serviceID: String, mockCase: MockCase) {
        guard let index = library.mockServices.firstIndex(where: { $0.id == serviceID }),
              let caseIndex = library.mockServices[index].cases.firstIndex(where: { $0.id == mockCase.id }) else { return }
        library.mockServices[index].cases[caseIndex] = mockCase
        persist()
        scheduleMockSync()
    }

    func moveMockService(from source: Int, to target: Int) {
        let reordered = ListOrdering.moved(library.mockServices, from: source, to: target)
        guard reordered.map(\.id) != library.mockServices.map(\.id) else { return }
        library.mockServices = reordered
        persist()
        syncMockServer()
    }

    func moveMockCase(serviceID: String, from source: Int, to target: Int) {
        guard let index = library.mockServices.firstIndex(where: { $0.id == serviceID }) else { return }
        let reordered = ListOrdering.moved(library.mockServices[index].cases, from: source, to: target)
        guard reordered.map(\.id) != library.mockServices[index].cases.map(\.id) else { return }
        library.mockServices[index].cases = reordered
        persist()
        syncMockServer()
    }

    func startMockServer(port: UInt16) {
        do {
            try mockServer.start(port: port, services: library.mockServices.filter(\.enabled))
        } catch {
            ui.alertMessage = error.localizedDescription
        }
    }

    func stopMockServer() {
        mockServer.stop()
    }

    private func syncMockServer() {
        guard mockServer.isRunning else { return }
        mockServer.update(services: library.mockServices)
    }

    /// Text edits arrive per keystroke (debounced by the editor, but still often). Rebuilding the
    /// running server's route table on every character would copy every case body repeatedly.
    private func scheduleMockSync() {
        mockSyncWorkItem?.cancel()
        guard mockServer.isRunning else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.syncMockServer()
        }
        mockSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func generateMockCollection(serviceID: String, port: UInt16) async -> String? {
        guard let service = library.mockServices.first(where: { $0.id == serviceID }) else { return nil }
        let collection = await Task.detached(priority: .userInitiated) {
            Self.buildMockCollection(service: service, port: port)
        }.value
        library.collections.append(collection)
        persist()
        return collection.info.name
    }

    private nonisolated static func buildMockCollection(service: MockService, port: UInt16) -> PMCollection {
        let prefix = service.normalizedPrefix
        var items: [CollectionItem] = []
        items.reserveCapacity(service.cases.count)
        for mockCase in service.cases {
            let fullPath = prefix == "/" ? mockCase.normalizedPath : prefix + mockCase.normalizedPath
            var draft = RequestDraft()
            draft.name = "\(service.name) · \(mockCase.name)"
            draft.method = mockCase.method.uppercased() == "ANY" ? "GET" : mockCase.method.uppercased()
            draft.urlRaw = "http://127.0.0.1:\(port)\(fullPath)"
            draft.headers = mockCase.headers.filter(\.isEnabled)
            if ["POST", "PUT", "PATCH"].contains(draft.method) {
                draft.bodyMode = .raw
                draft.rawLanguage = .json
                draft.rawBody = mockCase.requestBody
            }
            draft.testScript = """
            pm.test("status \(mockCase.effectiveStatusCode)", function () {
                pm.response.to.have.status(\(mockCase.effectiveStatusCode));
            });
            """
            var item = CollectionItem(name: draft.name, request: RequestDef())
            draft.materialize(into: &item)
            items.append(item)
        }
        return PMCollection(name: "Mock · \(service.name)", items: items)
    }

    // MARK: - Import / export

    func importFile(data: Data, filename: String) {
        do {
            var result = try ImportExport.decode(data: data, filename: filename)
            for index in result.collections.indices {
                result.collections[index].info._postman_id = UUID().uuidString
                var items = result.collections[index].items
                for itemIndex in items.indices {
                    reidentify(&items[itemIndex])
                }
                result.collections[index].item = items
            }
            for index in result.environments.indices {
                result.environments[index].id = UUID().uuidString
            }
            library.collections.append(contentsOf: result.collections)
            library.environments.append(contentsOf: result.environments)
            if !result.globals.isEmpty {
                for row in result.globals {
                    if let index = library.globals.firstIndex(where: { $0.key == row.key }) {
                        library.globals[index] = row
                    } else {
                        library.globals.append(row)
                    }
                }
            }
            if library.activeEnvironmentID == nil {
                library.activeEnvironmentID = library.environments.first?.id
            }
            persist()

            var message = "Imported \(result.collections.count) collection(s), \(result.environments.count) environment(s)."
            if !result.warnings.isEmpty {
                message += "\n\n" + result.warnings.prefix(6).joined(separator: "\n")
            }
            ui.alertMessage = message
        } catch {
            ui.alertMessage = error.localizedDescription
        }
    }

    func exportCollection(id: String) -> Data? {
        guard let collection = collection(id: id) else { return nil }
        return try? ImportExport.encodeCollection(collection)
    }

    func exportEnvironment(id: String) -> Data? {
        guard let environment = library.environments.first(where: { $0.id == id }) else { return nil }
        return try? ImportExport.encodeEnvironment(environment)
    }

    func exportBackup() -> Data? {
        try? ImportExport.encodeBackup(library)
    }

    func exportGlobals() -> Data? {
        try? ImportExport.encodeGlobals(library.globals)
    }

    func setCollectionAuth(id: String, auth: Auth) {
        guard let index = collectionIndex(id: id) else { return }
        library.collections[index].auth = auth
        persist()
    }

    func setCollectionVariables(id: String, values: [KeyValue]) {
        guard let index = collectionIndex(id: id) else { return }
        library.collections[index].variable = values.isEmpty ? nil : values
        persist()
    }

    func setCollectionScript(id: String, listen: String, source: String) {
        guard let index = collectionIndex(id: id) else { return }
        library.collections[index].setScript(listen: listen, source: source)
        persist()
    }

    func setFolderAuth(collectionID: String, itemID: String, auth: Auth) {
        guard let index = collectionIndex(id: collectionID) else { return }
        var items = library.collections[index].item ?? []
        CollectionTree.update(&items, id: itemID) { $0.auth = auth }
        library.collections[index].item = items
        persist()
    }

    func setFolderVariables(collectionID: String, itemID: String, values: [KeyValue]) {
        guard let index = collectionIndex(id: collectionID) else { return }
        var items = library.collections[index].item ?? []
        CollectionTree.update(&items, id: itemID) { $0.variable = values.isEmpty ? nil : values }
        library.collections[index].item = items
        persist()
    }

    func setFolderScript(collectionID: String, itemID: String, listen: String, source: String) {
        guard let index = collectionIndex(id: collectionID) else { return }
        var items = library.collections[index].item ?? []
        CollectionTree.update(&items, id: itemID) { $0.setScript(listen: listen, source: source) }
        library.collections[index].item = items
        persist()
    }

    // MARK: - Runner

    func startRunner() {
        guard !runner.isRunning,
              let collectionID = runner.selectedCollectionID,
              let collection = collection(id: collectionID) else { return }
        let requests = CollectionTree.flatten(collection)
        guard !requests.isEmpty else {
            ui.alertMessage = "This collection has no requests to run."
            return
        }
        runner.results = []
        runner.isRunning = true
        runner.stopRequested = false
        let settings = library.settings
        let cookies = cookieJar
        let iterations = max(1, runner.iterations)
        let delay = max(0, runner.delayMilliseconds)
        let dataRows = runner.dataRows.isEmpty ? [[:]] : runner.dataRows

        Task {
            var baseContext = VariableContext()
            baseContext.globals = dictionary(from: library.globals)
            baseContext.environment = dictionary(from: activeEnvironment?.values ?? [])
            baseContext.collection = dictionary(from: collection.variable ?? [])

            for iteration in 0..<iterations {
                if runner.stopRequested { break }
                let row = dataRows[iteration % dataRows.count]
                var index = 0
                while index < requests.count {
                    if runner.stopRequested { break }
                    let reference = requests[index]
                    var context = baseContext
                    context.data = row
                    runner.currentRequestName = reference.item.name
                    let draft = RequestDraft.make(from: reference.item)
                    var info = ScriptInfo(
                        requestName: reference.item.name,
                        requestID: reference.item.id,
                        iteration: iteration,
                        iterationCount: iterations,
                        eventName: "test"
                    )
                    info.iteration = iteration
                    var requestSettings = settings
                    requestSettings.followRedirects = draft.followRedirects
                    requestSettings.sslVerification = draft.strictSSL
                    let output = await Self.performSend(
                        draft: draft,
                        auth: reference.effectiveAuth,
                        context: context,
                        settings: requestSettings,
                        cookies: cookies,
                        info: info,
                        inheritedPreRequest: reference.inheritedScripts.preRequest,
                        inheritedTests: reference.inheritedScripts.tests,
                        spillDirectory: self.responseCacheDirectory
                    )
                    baseContext = output.context
                    let result = RunnerResult(
                        name: reference.item.name,
                        iteration: iteration + 1,
                        method: draft.method,
                        url: draft.urlRaw,
                        statusCode: output.result?.statusCode,
                        duration: output.result?.duration ?? 0,
                        tests: output.tests,
                        error: output.error
                    )
                    runner.results.append(result)

                    if let next = output.nextRequest {
                        if next.isEmpty {
                            index = requests.count
                            break
                        }
                        if let nextIndex = requests.firstIndex(where: { $0.item.name == next }) {
                            index = nextIndex
                            continue
                        }
                    }
                    index += 1
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    }
                }
            }
            runner.isRunning = false
            runner.currentRequestName = nil
            applyRunnerContext(baseContext, collectionID: collectionID)
        }
    }

    private func applyRunnerContext(_ context: VariableContext, collectionID: String) {
        if let id = library.activeEnvironmentID,
           let index = library.environments.firstIndex(where: { $0.id == id }) {
            var values = library.environments[index].values
            for (key, value) in context.environment {
                if let rowIndex = values.firstIndex(where: { $0.key == key }) {
                    values[rowIndex].value = value
                } else {
                    values.append(KeyValue(key: key, value: value))
                }
            }
            library.environments[index].values = values
        }
        var globals = library.globals
        for (key, value) in context.globals {
            if let rowIndex = globals.firstIndex(where: { $0.key == key }) {
                globals[rowIndex].value = value
            } else {
                globals.append(KeyValue(key: key, value: value))
            }
        }
        library.globals = globals
        if let index = collectionIndex(id: collectionID) {
            var values = library.collections[index].variable ?? []
            for (key, value) in context.collection {
                if let rowIndex = values.firstIndex(where: { $0.key == key }) {
                    values[rowIndex].value = value
                } else {
                    values.append(KeyValue(key: key, value: value))
                }
            }
            library.collections[index].variable = values.isEmpty ? nil : values
        }
        persist()
    }

    func loadRunnerData(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let rows = try RunnerDataParser.parse(data: data, filename: url.lastPathComponent)
            runner.dataRows = rows
            runner.dataFileName = url.lastPathComponent
        } catch {
            ui.alertMessage = error.localizedDescription
        }
    }

    // MARK: - Misc

    func showAlert(_ message: String) {
        ui.alertMessage = message
    }

    func variableSuggestions(for tab: RequestTab?) -> [VariableSuggestion] {
        var result: [VariableSuggestion] = []
        func append(_ rows: [KeyValue], scope: String) {
            for row in rows where !row.key.isEmpty {
                result.append(VariableSuggestion(
                    name: row.key,
                    value: row.value.isEmpty ? "(empty)" : row.value,
                    scope: scope,
                    note: row.description?.content
                ))
            }
        }
        append(library.globals, scope: "Globals")
        if let tab, let cid = tab.collectionID, let collection = collection(id: cid) {
            append(collection.variable ?? [], scope: "Collection")
        }
        if let environment = activeEnvironment {
            append(environment.values, scope: "Environment · \(environment.name)")
        }
        if let tab {
            for (key, value) in tab.localVariables.sorted(by: { $0.key < $1.key }) {
                result.append(VariableSuggestion(
                    name: key,
                    value: value.isEmpty ? "(empty)" : value,
                    scope: "Local",
                    note: nil
                ))
            }
        }
        for dynamic in DynamicVariableCatalog.all {
            result.append(VariableSuggestion(
                name: dynamic.name,
                value: dynamic.example,
                scope: "Dynamic",
                note: dynamic.description
            ))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    func resolveText(_ text: String) -> String {
        var context = VariableContext()
        context.globals = dictionary(from: library.globals)
        context.environment = dictionary(from: activeEnvironment?.values ?? [])
        return context.resolve(text)
    }
}

enum RunnerDataParser {
    static func parse(data: Data, filename: String) throws -> [[String: String]] {
        let extensionName = (filename as NSString).pathExtension.lowercased()
        if extensionName == "json" || filename.lowercased().hasSuffix(".json") {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let array = object as? [[String: Any]] else {
                throw ImportError.malformed("Runner data must be a JSON array of objects.")
            }
            return array.map { row in
                row.reduce(into: [String: String]()) { result, pair in
                    result[pair.key] = String(describing: pair.value)
                }
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        return try parseCSV(text)
    }

    static func parseCSV(_ text: String) throws -> [[String: String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        guard let header = rows.first, header.count > 0 else {
            throw ImportError.malformed("CSV has no header row.")
        }
        return rows.dropFirst().map { values in
            var dict: [String: String] = [:]
            for (column, name) in header.enumerated() {
                dict[name.trimmingCharacters(in: .whitespaces)] = column < values.count ? values[column] : ""
            }
            return dict
        }
    }
}
