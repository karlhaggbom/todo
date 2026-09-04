import Foundation
import SQLite3

/// SQLITE_TRANSIENT is a C macro; Swift needs it spelled out.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Thin SQLite C API wrapper

/// A minimal wrapper over the SQLite3 C API: just enough for the todo store.
/// No external dependencies; prepared statements are cached per SQL string.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]
    private let queue = DispatchQueue(label: "todo.sqlite")

    enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)
        case exec(String, sql: String)

        var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .prepare(let m, let sql): return "sqlite prepare failed: \(m) [\(sql)]"
            case .step(let m, let sql): return "sqlite step failed: \(m) [\(sql)]"
            case .exec(let m, let sql): return "sqlite exec failed: \(m) [\(sql)]"
            }
        }
    }

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw SQLiteError.open(message)
        }
        handle = db
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
    }

    deinit {
        cache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.exec(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    private func statement(for sql: String) throws -> Statement {
        if let cached = cache[sql] {
            cached.reset()
            return cached
        }
        let st = try Statement(db: handle, sql: sql)
        cache[sql] = st
        return st
    }

    // MARK: Statement

    final class Statement {
        private let db: OpaquePointer?
        private var handle: OpaquePointer?
        private var indices: [String: Int] = [:]

        init(db: OpaquePointer?, sql: String) throws {
            self.db = db
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
                throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            handle = st
            let count = sqlite3_column_count(st)
            for i in 0..<count {
                if let name = sqlite3_column_name(st, i) {
                    indices[String(cString: name)] = Int(i)
                }
            }
        }

        deinit {
            if let handle { sqlite3_finalize(handle) }
        }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        // Binding
        func bind(_ index: Int, _ value: Int64) { sqlite3_bind_int64(handle, Int32(index), value) }
        func bind(_ index: Int, _ value: Double) { sqlite3_bind_double(handle, Int32(index), value) }
        func bind(_ index: Int, _ value: String) { sqlite3_bind_text(handle, Int32(index), value, -1, SQLITE_TRANSIENT) }
        func bind(_ index: Int, _ value: Data?) {
            guard let value, !value.isEmpty else { bindNull(index); return }
            // Bind inside withUnsafeBytes: with SQLITE_TRANSIENT, sqlite copies
            // the bytes during the bind call itself, so the pointer is consumed
            // before the scope that guarantees it ends.
            _ = value.withUnsafeBytes { raw in
                sqlite3_bind_blob(handle, Int32(index), raw.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
        }
        func bind(_ index: Int, _ value: Bool) { sqlite3_bind_int(handle, Int32(index), value ? 1 : 0) }
        func bindNull(_ index: Int) { sqlite3_bind_null(handle, Int32(index)) }

        private func bindNamed(_ name: String, _ bind: (Int) -> Void) {
            guard let idx = indices[name] else { return }
            bind(idx + 1)
        }
        func bind(_ name: String, _ value: Int64) { bindNamed(name) { bind($0, value) } }
        func bind(_ name: String, _ value: Double) { bindNamed(name) { bind($0, value) } }
        func bind(_ name: String, _ value: String) { bindNamed(name) { bind($0, value) } }
        func bind(_ name: String, _ value: Bool) { bindNamed(name) { bind($0, value) } }
        func bind(_ name: String, _ value: Data?) { bindNamed(name) { bind($0, value) } }
        func bindNull(_ name: String) { bindNamed(name) { bindNull($0) } }

        // Column access
        var columnCount: Int { Int(sqlite3_column_count(handle)) }
        func hasColumn(_ name: String) -> Bool { indices[name] != nil }

        func int(_ index: Int) -> Int64 { sqlite3_column_int64(handle, Int32(index)) }
        func double(_ index: Int) -> Double { sqlite3_column_double(handle, Int32(index)) }
        func string(_ index: Int) -> String {
            guard let c = sqlite3_column_text(handle, Int32(index)) else { return "" }
            return String(cString: c)
        }
        func optionalString(_ index: Int) -> String? {
            guard sqlite3_column_type(handle, Int32(index)) != SQLITE_NULL else { return nil }
            return string(index)
        }
        func optionalInt(_ index: Int) -> Int? {
            guard sqlite3_column_type(handle, Int32(index)) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(handle, Int32(index)))
        }
        func data(_ index: Int) -> Data? {
            guard let blob = sqlite3_column_blob(handle, Int32(index)) else { return nil }
            let count = Int(sqlite3_column_bytes(handle, Int32(index)))
            return Data(bytes: blob, count: count)
        }
        func bool(_ index: Int) -> Bool { sqlite3_column_int(handle, Int32(index)) != 0 }

        func int(_ name: String) -> Int64 { int(indices[name] ?? 0) }
        func double(_ name: String) -> Double { double(indices[name] ?? 0) }
        func string(_ name: String) -> String { string(indices[name] ?? 0) }
        func optionalString(_ name: String) -> String? { optionalString(indices[name] ?? 0) }
        func optionalInt(_ name: String) -> Int? { optionalInt(indices[name] ?? 0) }
        func data(_ name: String) -> Data? { data(indices[name] ?? 0) }
        func bool(_ name: String) -> Bool { bool(indices[name] ?? 0) }

        enum Step { case row, done }

        @discardableResult
        func step() throws -> Step {
            let rc = sqlite3_step(handle)
            switch rc {
            case SQLITE_ROW: return .row
            case SQLITE_DONE: return .done
            default:
                throw SQLiteError.step(String(cString: sqlite3_errmsg(db)), sql: "<statement>")
            }
        }
    }

    // MARK: Public API

    /// Run a statement that returns no rows.
    func run(_ sql: String, _ bindings: (Statement) -> Void = { _ in }) throws {
        let st = try statement(for: sql)
        bindings(st)
        try st.step()
    }

    /// Run a statement, mapping each row via `map`.
    func query<T>(_ sql: String, _ bindings: (Statement) -> Void = { _ in }, map: (Statement) -> T) throws -> [T] {
        let st = try statement(for: sql)
        bindings(st)
        var results: [T] = []
        while try st.step() == .row {
            results.append(map(st))
        }
        return results
    }

    /// Run multiple statements (no binding) — for schema setup.
    func execute(_ sql: String) throws {
        try exec(sql)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Run `body` inside a transaction. Rolls back on error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}