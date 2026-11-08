import Foundation
import SQLite3

/// Where the SDK keeps the inbox between launches.
public protocol NotifyCache: Sendable {
    func load(key: String) -> Data?
    func save(key: String, value: Data)
}

/// SQLite cache: one row per subscriber key in `snapshots`. Thread-safe (serialized connection).
public final class SQLiteCache: NotifyCache, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Opens (or creates) the database; defaults to Caches/notify.sqlite.
    public init?(path: String? = nil) {
        let file = path ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("notify.sqlite").path
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS snapshots (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT

    public func load(key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM snapshots WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    public func save(key: String, value: Data) {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO snapshots (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(value.count), Self.transient) }
        sqlite3_step(stmt)
    }
}
