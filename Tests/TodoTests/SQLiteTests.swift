import Testing
import Foundation
@testable import Todo

/// SQLite wrapper behavior: parameter binding, column mapping,
/// transactions, and persistence across connections.
@Suite struct SQLiteTests {
    private func tempPath() -> String {
        "\(NSTemporaryDirectory())/todo-sqlite-test-\(UUID().uuidString).sqlite3"
    }

    private func makeFreshTable(db: SQLiteDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score REAL NOT NULL)")
    }

    @Test func queryBindsParametersAndMapsColumnsByName() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try makeFreshTable(db: db)
        try db.run("INSERT INTO items (name, score) VALUES (?, ?)") { st in
            st.bind(1, "alpha")
            st.bind(2, 2.5)
        }
        let rows = try db.query("SELECT * FROM items WHERE name = ?", { st in st.bind(1, "alpha") }) { st in
            (name: st.string("name"), score: st.double("score"))
        }
        #expect(rows.count == 1)
        #expect(rows[0].name == "alpha")
        #expect(abs(rows[0].score - 2.5) < 0.0001)
    }

    @Test func queryWithNoMatchReturnsEmptyArray() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try makeFreshTable(db: db)
        try db.run("INSERT INTO items (name, score) VALUES (?, ?)") { st in
            st.bind(1, "alpha"); st.bind(2, 2.5)
        }
        let rows = try db.query("SELECT * FROM items WHERE name = ?", { st in st.bind(1, "nope") }) { _ in 1 }
        #expect(rows.isEmpty)
    }

    @Test func transactionRollsBackWhenBodyThrows() throws {
        struct Boom: Error {}
        let db = try SQLiteDatabase(path: ":memory:")
        try makeFreshTable(db: db)
        do {
            try db.transaction {
                try db.run("INSERT INTO items (name, score) VALUES ('keep-me-out', 1.0)")
                throw Boom()
            }
            Issue.record("transaction must throw when the body throws")
        } catch {}
        let count = try db.query("SELECT COUNT(*) AS n FROM items", map: { $0.int("n") })
        #expect(count.first ?? 0 == 0, "rolled-back insert must not persist")
    }

    @Test func transactionCommitsWhenBodySucceeds() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try makeFreshTable(db: db)
        try db.transaction {
            try db.run("INSERT INTO items (name, score) VALUES ('persist', 1.0)")
        }
        let count = try db.query("SELECT COUNT(*) AS n FROM items", map: { $0.int("n") })
        #expect(count.first ?? -1 == 1)
    }

    @Test func dataPersistsAcrossSeparateConnections() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let db = try SQLiteDatabase(path: path)
            try makeFreshTable(db: db)
            try db.run("INSERT INTO items (name, score) VALUES ('durable', 7.0)")
        }
        // Reopen from disk with a fresh connection.
        let db2 = try SQLiteDatabase(path: path)
        let names = try db2.query("SELECT name FROM items", map: { $0.string("name") })
        #expect(names == ["durable"])
    }

    @Test func foreignKeysEnforcedWithCascadeDelete() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("""
        CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
        CREATE TABLE child (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL REFERENCES parent(id) ON DELETE CASCADE);
        """)
        try db.run("INSERT INTO parent (name) VALUES ('p1')")
        try db.run("INSERT INTO child (parent_id) VALUES (1)")
        try db.run("INSERT INTO child (parent_id) VALUES (1)")
        try db.run("DELETE FROM parent WHERE id = 1")

        let orphans = try db.query("SELECT COUNT(*) AS n FROM child", map: { $0.int("n") })
        #expect(orphans.first ?? -1 == 0, "children must cascade when parent is deleted")

        do {
            try db.run("INSERT INTO child (parent_id) VALUES (999)")
            Issue.record("insert with dangling parent reference must be rejected (foreign_keys=ON)")
        } catch {}
    }
}