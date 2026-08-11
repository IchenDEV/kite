import CSQLite
import Foundation

private nonisolated(unsafe) let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

enum HistoryStoreError: LocalizedError, Sendable {
    case open(String)
    case execute(String)
    case prepare(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): "Could not open history database: \(message)"
        case let .execute(message): "History database error: \(message)"
        case let .prepare(message): "Could not prepare history query: \(message)"
        }
    }
}

actor HistoryStore {
    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.pointer }

    init(databaseURL: URL? = nil) throws {
        let url: URL
        if let databaseURL {
            url = databaseURL
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appending(path: "SuperDD", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appending(path: "history.sqlite3")
        }

        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let pointer { sqlite3_close(pointer) }
            throw HistoryStoreError.open(message)
        }
        guard let pointer else { throw HistoryStoreError.open("SQLite returned no database handle") }
        connection = SQLiteConnection(pointer: pointer)
        try Self.execute(
            database: pointer,
            sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS download_history (
                gid TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                status TEXT NOT NULL,
                total_length INTEGER NOT NULL,
                completed_length INTEGER NOT NULL,
                directory TEXT NOT NULL,
                completed_at REAL NOT NULL,
                source_url TEXT,
                source_file_path TEXT,
                retry_options BLOB,
                error_message TEXT,
                label TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_download_history_completed_at
                ON download_history(completed_at DESC);
            """
        )
        try Self.migrateColumnsIfNeeded(database: pointer)
    }

    func upsert(task: DownloadTask, metadata: TaskMetadata? = nil, at date: Date = .now) throws {
        guard task.status.isTerminal else { return }
        let sql = """
        INSERT INTO download_history
            (gid, name, status, total_length, completed_length, directory, completed_at,
             source_url, source_file_path, retry_options, error_message, label)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(gid) DO UPDATE SET
            name = excluded.name,
            status = excluded.status,
            total_length = excluded.total_length,
            completed_length = excluded.completed_length,
            directory = excluded.directory,
            completed_at = excluded.completed_at,
            source_url = excluded.source_url,
            source_file_path = excluded.source_file_path,
            retry_options = excluded.retry_options,
            error_message = excluded.error_message,
            label = excluded.label;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(task.gid, to: 1, statement: statement)
        bind(task.name, to: 2, statement: statement)
        bind(task.status.rawValue, to: 3, statement: statement)
        sqlite3_bind_int64(statement, 4, task.totalLength)
        sqlite3_bind_int64(statement, 5, task.completedLength)
        bind(task.directory, to: 6, statement: statement)
        sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
        bindOptional(metadata?.sourceURLs.first ?? task.files.flatMap(\.uris).first?.uri, to: 8, statement: statement)
        bindOptional(metadata?.sourceFilePath, to: 9, statement: statement)
        if let metadata, let data = try? JSONEncoder().encode(metadata.options) {
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 10, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        } else {
            sqlite3_bind_null(statement, 10)
        }
        bindOptional(task.errorMessage, to: 11, statement: statement)
        bind(metadata?.label ?? "", to: 12, statement: statement)
        try step(statement)
    }

    func records(limit: Int = 1_000) throws -> [HistoryRecord] {
        let statement = try prepare(
            """
            SELECT gid, name, status, total_length, completed_length, directory, completed_at,
                   source_url, source_file_path, retry_options, error_message, label
            FROM download_history
            ORDER BY completed_at DESC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: limit))

        var result: [HistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                HistoryRecord(
                    id: text(statement, column: 0),
                    name: text(statement, column: 1),
                    status: DownloadStatus(rawValue: text(statement, column: 2)) ?? .unknown,
                    totalLength: sqlite3_column_int64(statement, 3),
                    completedLength: sqlite3_column_int64(statement, 4),
                    directory: text(statement, column: 5),
                    completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    sourceURL: optionalText(statement, column: 7),
                    sourceFilePath: optionalText(statement, column: 8),
                    retryOptions: retryOptions(statement, column: 9),
                    errorMessage: optionalText(statement, column: 10),
                    label: optionalText(statement, column: 11) ?? ""
                )
            )
        }
        return result
    }

    func remove(id: String) throws {
        let statement = try prepare("DELETE FROM download_history WHERE gid = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, statement: statement)
        try step(statement)
    }

    func removeAll() throws {
        try Self.execute(database: database, sql: "DELETE FROM download_history;")
    }

    func integrityCheck() throws -> String {
        let statement = try prepare("PRAGMA integrity_check;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoryStoreError.execute(errorMessage)
        }
        return text(statement, column: 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.prepare(errorMessage)
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptional(_ value: String?, to index: Int32, statement: OpaquePointer) {
        if let value { bind(value, to: index, statement: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.execute(errorMessage)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private func retryOptions(_ statement: OpaquePointer, column: Int32) -> [String: JSONValue] {
        guard let bytes = sqlite3_column_blob(statement, column) else { return [:] }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return [:] }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: Data(bytes: bytes, count: count))) ?? [:]
    }

    private static func migrateColumnsIfNeeded(database: OpaquePointer) throws {
        let required: [(String, String)] = [
            ("source_url", "TEXT"),
            ("source_file_path", "TEXT"),
            ("retry_options", "BLOB"),
            ("error_message", "TEXT"),
            ("label", "TEXT NOT NULL DEFAULT ''"),
        ]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(download_history);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryStoreError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        var existing = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) { existing.insert(String(cString: value)) }
        }
        sqlite3_finalize(statement)
        for (name, type) in required where !existing.contains(name) {
            try execute(database: database, sql: "ALTER TABLE download_history ADD COLUMN \(name) \(type);")
        }
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw HistoryStoreError.execute(message)
        }
    }
}
