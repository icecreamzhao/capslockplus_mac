import Foundation
import Darwin
import SQLite3

enum TelemetryBufferError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    var description: String {
        switch self {
        case .open(let message): return "telemetry buffer open: \(message)"
        case .sql(let message): return "telemetry buffer sql: \(message)"
        }
    }
}

/// 未发送批次队列。一批 = 一次 POST 的 JSON BLOB，语义上是 FIFO。
final class TelemetryBuffer {
    struct StoredBatch {
        let id: Int64
        let createdAt: Date
        let payload: Data
    }

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let path: String

    init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw TelemetryBufferError.open(message)
        }
        db = handle
        do {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
            try exec("PRAGMA busy_timeout=5000;")
            try exec("""
                CREATE TABLE IF NOT EXISTS pending (
                    id INTEGER PRIMARY KEY,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """)
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
        for suffix in ["", "-wal", "-shm"] {
            chmod(path + suffix, 0o600)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    @discardableResult
    func enqueue(_ payload: Data, createdAt: Date = Date()) throws -> Int64 {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
                                    "INSERT INTO pending (created_at, payload) VALUES (?, ?)",
                                    -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, createdAt.timeIntervalSince1970)
        payload.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(sqlite3_errcode(db)) }
        return sqlite3_last_insert_rowid(db)
    }

    func dequeue(limit: Int) throws -> [StoredBatch] {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
                                    "SELECT id, created_at, payload FROM pending ORDER BY id ASC LIMIT ?",
                                    -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(1, limit)))

        var batches: [StoredBatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let bytes = Int(sqlite3_column_bytes(statement, 2))
            let payload: Data
            if let blob = sqlite3_column_blob(statement, 2), bytes > 0 {
                payload = Data(bytes: blob, count: bytes)
            } else {
                payload = Data()
            }
            batches.append(StoredBatch(id: id, createdAt: createdAt, payload: payload))
        }
        return batches
    }

    func delete(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "DELETE FROM pending WHERE id = ?", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error(sqlite3_errcode(db)) }
            sqlite3_reset(statement)
        }
    }

    func count() throws -> Int {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func stats() throws -> (batches: Int, bytes: Int) {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db,
                                    "SELECT COUNT(*), IFNULL(SUM(LENGTH(payload)), 0) FROM pending",
                                    -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(statement, 0)),
                Int(sqlite3_column_int64(statement, 1)))
    }

    func oldestCreatedAt() throws -> Date? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT MIN(created_at) FROM pending", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// 超过字节上限或 7 天：从最老的开始删。返回删掉的批次数。
    @discardableResult
    func prune(maxBytes: Int, maxAge: TimeInterval, now: Date = Date()) throws -> Int {
        var removed = 0
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "DELETE FROM pending WHERE created_at < ?", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970 - maxAge)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let code = sqlite3_errcode(db)
            sqlite3_finalize(statement)
            throw error(code)
        }
        sqlite3_finalize(statement)
        removed += Int(sqlite3_changes(db))

        while true {
            let currentBytes = try stats().bytes
            if currentBytes <= maxBytes { break }
            guard let oldest = try dequeue(limit: 1).first else { break }
            try delete(ids: [oldest.id])
            removed += 1
        }
        return removed
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "rc=\(rc)"
            if let message { sqlite3_free(UnsafeMutableRawPointer(message)) }
            throw TelemetryBufferError.sql(text)
        }
        if let message { sqlite3_free(UnsafeMutableRawPointer(message)) }
    }

    private func error(_ code: Int32) -> TelemetryBufferError {
        guard let db else { return .sql("db closed") }
        return .sql("rc=\(code) \(String(cString: sqlite3_errmsg(db)))")
    }
}
