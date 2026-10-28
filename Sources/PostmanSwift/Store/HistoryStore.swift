import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class HistoryStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let bodiesDirectory: URL

    init(path: String) {
        bodiesDirectory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("history-bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
        sqlite3_open(path, &database)
        execSQL("""
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            status INTEGER NOT NULL,
            duration REAL NOT NULL,
            size INTEGER NOT NULL,
            collection_id TEXT,
            collection_name TEXT,
            request_name TEXT,
            request_json BLOB NOT NULL,
            headers_json BLOB,
            response_body BLOB,
            response_text TEXT,
            mime TEXT
        );
        """)
        execSQL("CREATE INDEX IF NOT EXISTS history_ts ON history(ts DESC);")
        // Columns added after the first schema shipped; ALTER failures are expected on re-run.
        execSQL("ALTER TABLE history ADD COLUMN item_id TEXT;")
        execSQL("ALTER TABLE history ADD COLUMN request_resolved_json BLOB;")
        execSQL("ALTER TABLE history ADD COLUMN timings_json BLOB;")
        execSQL("ALTER TABLE history ADD COLUMN response_body_path TEXT;")
        execSQL("CREATE INDEX IF NOT EXISTS history_item ON history(item_id, ts DESC);")
    }

    deinit {
        sqlite3_close(database)
    }

    func insert(_ entry: HistoryEntry, limit: Int = 2000) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        guard let requestData = try? encoder.encode(entry.request) else { return }
        let headersData = try? encoder.encode(entry.responseHeaders)
        let resolvedData = entry.resolvedRequest.flatMap { try? encoder.encode($0) }
        let timingsData = entry.timings.flatMap { try? encoder.encode($0) }

        var storedBody = entry.responseBody
        var bodyPath: String?
        if let source = entry.responseBodySourceURL {
            let destination = bodiesDirectory.appendingPathComponent("\(entry.id).bin")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                bodyPath = destination.path
                storedBody = nil
            }
        }
        let storedText = (storedBody == nil && bodyPath == nil) ? entry.responseText : nil

        let sql = """
        INSERT OR REPLACE INTO history
        (id, ts, method, url, status, duration, size, collection_id, collection_name, request_name,
         request_json, headers_json, response_body, response_text, mime,
         item_id, request_resolved_json, timings_json, response_body_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, entry.id)
        sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
        bind(statement, 3, entry.method)
        bind(statement, 4, entry.url)
        sqlite3_bind_int(statement, 5, Int32(entry.statusCode))
        sqlite3_bind_double(statement, 6, entry.duration)
        sqlite3_bind_int(statement, 7, Int32(entry.responseSize))
        bindOptional(statement, 8, entry.collectionID)
        bindOptional(statement, 9, entry.collectionName)
        bindOptional(statement, 10, entry.requestName)
        bindData(statement, 11, requestData)
        if let headersData { bindData(statement, 12, headersData) } else { sqlite3_bind_null(statement, 12) }
        if let storedBody { bindData(statement, 13, storedBody) } else { sqlite3_bind_null(statement, 13) }
        bindOptional(statement, 14, storedText)
        bindOptional(statement, 15, entry.mimeType)
        bindOptional(statement, 16, entry.itemID)
        if let resolvedData { bindData(statement, 17, resolvedData) } else { sqlite3_bind_null(statement, 17) }
        if let timingsData { bindData(statement, 18, timingsData) } else { sqlite3_bind_null(statement, 18) }
        bindOptional(statement, 19, bodyPath)
        sqlite3_step(statement)

        execSQL("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY ts DESC LIMIT \(limit));")
    }

    /// Loads only the columns the sidebar renders. Response bodies are skipped so a history of
    /// multi-megabyte payloads never has to be materialised just to draw the list.
    func fetch(limit: Int = 500, search: String? = nil) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        var sql = """
        SELECT id, ts, method, url, status, duration, size, collection_id, collection_name, request_name, mime
        FROM history
        """
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            sql += " WHERE url LIKE ? OR method LIKE ? OR request_name LIKE ?"
        }
        sql += " ORDER BY ts DESC LIMIT ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if !trimmed.isEmpty {
            let pattern = "%\(trimmed)%"
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
            bind(statement, index, pattern); index += 1
        }
        sqlite3_bind_int(statement, index, Int32(limit))

        var results: [HistoryEntry] = []
        results.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0),
                  let method = text(statement, 2),
                  let url = text(statement, 3) else { continue }
            results.append(HistoryEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                method: method,
                url: url,
                statusCode: Int(sqlite3_column_int(statement, 4)),
                duration: sqlite3_column_double(statement, 5),
                responseSize: Int(sqlite3_column_int(statement, 6)),
                collectionID: text(statement, 7),
                collectionName: text(statement, 8),
                requestName: text(statement, 9),
                request: RequestDef(),
                responseHeaders: [],
                responseBody: nil,
                responseText: nil,
                mimeType: text(statement, 10),
                isSummary: true
            ))
        }
        return results
    }

    /// Recent executions of one collection item, summaries only (no bodies).
    func fetch(itemID: String, limit: Int = 25) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT id, ts, method, url, status, duration, size, collection_id, collection_name, request_name, mime
        FROM history WHERE item_id = ? ORDER BY ts DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, itemID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [HistoryEntry] = []
        results.reserveCapacity(limit)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0),
                  let method = text(statement, 2),
                  let url = text(statement, 3) else { continue }
            results.append(HistoryEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                method: method,
                url: url,
                statusCode: Int(sqlite3_column_int(statement, 4)),
                duration: sqlite3_column_double(statement, 5),
                responseSize: Int(sqlite3_column_int(statement, 6)),
                collectionID: text(statement, 7),
                collectionName: text(statement, 8),
                requestName: text(statement, 9),
                request: RequestDef(),
                responseHeaders: [],
                responseBody: nil,
                responseText: nil,
                mimeType: text(statement, 10),
                itemID: itemID,
                isSummary: true
            ))
        }
        return results
    }

    /// Loads the full request and response for a single row.
    func fetchDetail(id: String) -> HistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return detailLocked(id: id)
    }

    /// Latest full row for a collection item, used to restore "last response" when a request is
    /// reopened, including after an app restart.
    func latestDetail(itemID: String) -> HistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM history WHERE item_id = ? ORDER BY ts DESC LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, itemID)
        guard sqlite3_step(statement) == SQLITE_ROW, let id = text(statement, 0) else { return nil }
        return detailLocked(id: id)
    }

    private func detailLocked(id: String) -> HistoryEntry? {
        let sql = """
        SELECT id, ts, method, url, status, duration, size, collection_id, collection_name, request_name,
               request_json, headers_json, response_body, response_text, mime,
               item_id, request_resolved_json, timings_json, response_body_path
        FROM history WHERE id = ? LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rowID = text(statement, 0),
              let method = text(statement, 2),
              let url = text(statement, 3) else { return nil }
        let decoder = JSONDecoder()
        let request = data(statement, 10).flatMap { try? decoder.decode(RequestDef.self, from: $0) } ?? RequestDef()
        let headers = data(statement, 11).flatMap { try? decoder.decode([KeyValue].self, from: $0) } ?? []
        let resolved = data(statement, 16).flatMap { try? decoder.decode(ResolvedRequest.self, from: $0) }
        let timings = data(statement, 17).flatMap { try? decoder.decode(RequestTimings.self, from: $0) }
        let bodyPath = text(statement, 18)
        let body = data(statement, 12) ?? bodyPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        return HistoryEntry(
            id: rowID,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            method: method,
            url: url,
            statusCode: Int(sqlite3_column_int(statement, 4)),
            duration: sqlite3_column_double(statement, 5),
            responseSize: Int(sqlite3_column_int(statement, 6)),
            collectionID: text(statement, 7),
            collectionName: text(statement, 8),
            requestName: text(statement, 9),
            request: request,
            responseHeaders: headers,
            responseBody: body,
            responseText: text(statement, 13),
            mimeType: text(statement, 14),
            itemID: text(statement, 15),
            resolvedRequest: resolved,
            timings: timings,
            responseBodyPath: bodyPath,
            isSummary: false
        )
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        execSQL("DELETE FROM history;")
        if let files = try? FileManager.default.contentsOfDirectory(at: bodiesDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM history WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_step(statement)
        try? FileManager.default.removeItem(at: bodiesDirectory.appendingPathComponent("\(id).bin"))
    }

    // MARK: - SQLite helpers

    private func execSQL(_ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptional(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindData(_ statement: OpaquePointer?, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func data(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }
}
