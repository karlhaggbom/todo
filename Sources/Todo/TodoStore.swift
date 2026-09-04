import Foundation
import Combine

/// Observable SQLite-backed store for local lanes/tasks and Jira accounts/spaces.
/// All mutations write to SQLite immediately, then reload affected state.
public final class TodoStore: ObservableObject {
    @Published private(set) var lanes: [Lane] = []
    @Published private(set) var tasks: [TodoTask] = []
    @Published private(set) var jiraAccounts: [JiraAccount] = []
    @Published private(set) var jiraSpaces: [JiraSpace] = []
    @Published private(set) var githubAccounts: [GitHubAccount] = []
    @Published private(set) var githubRepos: [GitHubRepo] = []
    /// Issues the user has opened (read) from the mentions pages. Key
    /// formats: "TAP-123" (Jira), "owner/repo#123" (GitHub). Kept in sync
    /// with the read_issues table so filtering is instant, client-side.
    @Published private(set) var readIssueKeys: Set<String> = []

    let db: SQLiteDatabase
    /// Keychain namespace for API tokens. Tests inject a private service so
    /// they never touch the user's real keychain items.
    let keychainService: String

    public init(databasePath: String? = nil, keychainService: String? = nil) {
        self.keychainService = keychainService ?? KeychainStore.defaultService
        let path = databasePath ?? Self.defaultDatabasePath()
        do {
            if path != ":memory:" {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
            }
            db = try SQLiteDatabase(path: path)
            try migrate()
            try seedLanesIfNeeded()
            try reloadAll()
        } catch {
            fatalError("TodoStore init failed: \(error)")
        }
    }

    static func defaultDatabasePath() -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent("Todo/todo.sqlite3").path
    }

    // In-memory variant for tests/previews.
    static func inMemory() -> TodoStore {
        TodoStore(databasePath: ":memory:")
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS lanes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            position REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lane_id INTEGER NOT NULL REFERENCES lanes(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            position REAL NOT NULL,
            created_at REAL NOT NULL,
            completed_at REAL
        );
        CREATE TABLE IF NOT EXISTS jira_accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL,
            base_url TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS jira_spaces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            project_key TEXT NOT NULL,
            jql TEXT,
            board_id INTEGER
        );
        CREATE TABLE IF NOT EXISTS github_accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            base_url TEXT NOT NULL,
            login TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS github_repos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL REFERENCES github_accounts(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            owner TEXT NOT NULL,
            repo TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS board_cache (
            key TEXT PRIMARY KEY,
            data BLOB NOT NULL,
            fetched_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS read_issues (
            key TEXT PRIMARY KEY,
            read_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_lane ON tasks(lane_id, position);
        """)
        // Older databases predate the pinned-board column on jira_spaces.
        let spaceColumns = try db.query("PRAGMA table_info(jira_spaces)", map: { $0.string("name") })
        if !spaceColumns.contains("board_id") {
            try db.execute("ALTER TABLE jira_spaces ADD COLUMN board_id INTEGER")
        }
    }

    private func seedLanesIfNeeded() throws {
        let count: Int64 = try {
            try db.query("SELECT COUNT(*) AS n FROM lanes", map: { $0.int("n") }).first ?? 0
        }()
        guard count == 0 else { return }
        try db.transaction {
            try db.run("INSERT INTO lanes (name, position) VALUES (?, ?)") { st in
                st.bind(1, "Backlog"); st.bind(2, 0.0)
            }
            try db.run("INSERT INTO lanes (name, position) VALUES (?, ?)") { st in
                st.bind(1, "Doing"); st.bind(2, 1.0)
            }
            try db.run("INSERT INTO lanes (name, position) VALUES (?, ?)") { st in
                st.bind(1, "Done"); st.bind(2, 2.0)
            }
        }
    }

    // MARK: - Loading

    func reloadAll() throws {
        lanes = try db.query("SELECT * FROM lanes ORDER BY position", map: Self.lane(from:))
        tasks = try db.query("SELECT * FROM tasks ORDER BY position", map: Self.task(from:))
        jiraAccounts = try db.query("SELECT * FROM jira_accounts ORDER BY id", map: Self.account(from:))
        jiraSpaces = try db.query("SELECT * FROM jira_spaces ORDER BY id", map: Self.space(from:))
        githubAccounts = try db.query("SELECT * FROM github_accounts ORDER BY id", map: Self.gitHubAccount(from:))
        githubRepos = try db.query("SELECT * FROM github_repos ORDER BY id", map: Self.gitHubRepo(from:))
        readIssueKeys = Set(try db.query("SELECT key FROM read_issues", map: { $0.string("key") }))
    }

    /// Mark an issue as read (the user opened it from mentions).
    /// Idempotent; writes through to SQLite immediately.
    func markIssueRead(_ key: String) {
        guard !readIssueKeys.contains(key) else { return }
        readIssueKeys.insert(key)
        do {
            try db.run("INSERT OR IGNORE INTO read_issues (key, read_at) VALUES (?, ?)") { st in
                st.bind(1, key)
                st.bind(2, Date().timeIntervalSince1970)
            }
        } catch {
            Diag.log.error("mark-read failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func lane(from st: SQLiteDatabase.Statement) -> Lane {
        Lane(id: st.int("id"), name: st.string("name"), position: st.double("position"))
    }

    private static func task(from st: SQLiteDatabase.Statement) -> TodoTask {
        TodoTask(
            id: st.int("id"),
            laneID: st.int("lane_id"),
            title: st.string("title"),
            notes: st.string("notes"),
            position: st.double("position"),
            createdAt: Date(timeIntervalSince1970: st.double("created_at")),
            completedAt: st.optionalString("completed_at").flatMap {
                Double($0).map { Date(timeIntervalSince1970: $0) }
            }
        )
    }

    private static func account(from st: SQLiteDatabase.Statement) -> JiraAccount {
        JiraAccount(id: st.int("id"), name: st.string("name"), email: st.string("email"), baseURL: st.string("base_url"))
    }

    private static func space(from st: SQLiteDatabase.Statement) -> JiraSpace {
        JiraSpace(id: st.int("id"), accountID: st.int("account_id"), name: st.string("name"), projectKey: st.string("project_key"), jql: st.optionalString("jql"), boardID: st.optionalInt("board_id"))
    }

    private static func gitHubAccount(from st: SQLiteDatabase.Statement) -> GitHubAccount {
        GitHubAccount(id: st.int("id"), name: st.string("name"), baseURL: st.string("base_url"), login: st.string("login"))
    }

    private static func gitHubRepo(from st: SQLiteDatabase.Statement) -> GitHubRepo {
        GitHubRepo(id: st.int("id"), accountID: st.int("account_id"), name: st.string("name"), owner: st.string("owner"), repo: st.string("repo"))
    }

    // MARK: - Derived

    func laneTasks(_ laneID: Int64) -> [TodoTask] {
        tasks.filter { $0.laneID == laneID }
    }

    func lane(named name: String) -> Lane? {
        lanes.first { $0.name == name }
    }

    // MARK: - Position math

    /// Midpoint between neighbors; renormalizes lane positions if the gap gets
    /// too small to keep REAL precision healthy.
    /// Compute the drop position for a new item at `index` in the lane,
    /// evaluated against the lane *without* the new item present.
    private func newPosition(inLane laneID: Int64, before index: Int? = nil) throws -> Double {
        var laneTasks = laneTasks(laneID)
        // Renormalize FIRST if the spread got unhealthy, so the midpoint below
        // is computed against the freshly-spaced layout.
        if laneTasks.count > 1,
           (laneTasks.map(\.position).max()! - laneTasks.map(\.position).min()!) > 1e12 {
            try renormalize(laneID: laneID)
            laneTasks = self.laneTasks(laneID)
        }
        let pos: Double
        if laneTasks.isEmpty {
            pos = 1.0
        } else if let index, index > 0, index < laneTasks.count {
            pos = (laneTasks[index - 1].position + laneTasks[index].position) / 2
        } else if let index, index <= 0 {
            pos = laneTasks.first!.position - 1.0
        } else {
            pos = laneTasks.last!.position + 1.0
        }
        return pos
    }

    /// Re-space all tasks in a lane to 1.0, 2.0, 3.0, ...
    private func renormalize(laneID: Int64) throws {
        let laneTasks = laneTasks(laneID)
        try db.transaction {
            for (i, t) in laneTasks.enumerated() {
                try db.run("UPDATE tasks SET position = ? WHERE id = ?") { st in
                    st.bind(1, Double(i + 1))
                    st.bind(2, t.id)
                }
            }
        }
        try reloadTasks()
    }

    private func reloadTasks() throws {
        tasks = try db.query("SELECT * FROM tasks ORDER BY position", map: Self.task(from:))
    }

    // MARK: - Task mutations

    @discardableResult
    func addTask(title: String, notes: String = "", laneID: Int64? = nil, at index: Int? = nil) throws -> TodoTask {
        let targetLane = laneID ?? lanes.first!.id
        // Compute the position from the lane as it is *before* the insert.
        let pos = try newPosition(inLane: targetLane, before: index)
        try db.run("INSERT INTO tasks (lane_id, title, notes, position, created_at) VALUES (?, ?, ?, ?, ?)") { st in
            st.bind(1, targetLane)
            st.bind(2, title)
            st.bind(3, notes)
            st.bind(4, pos)
            st.bind(5, Date().timeIntervalSince1970)
        }
        let id = db.lastInsertRowID
        // A task created directly in the "Done" lane counts as completed.
        if targetLane == lane(named: "Done")?.id {
            try db.run("UPDATE tasks SET completed_at = ? WHERE id = ?") { st in
                st.bind(1, String(Date().timeIntervalSince1970)); st.bind(2, id)
            }
        }
        try reloadTasks()
        return tasks.first { $0.id == id }!
    }

    func updateTask(_ id: Int64, title: String? = nil, notes: String? = nil) throws {
        var sets: [String] = []
        if let title { sets.append("title = ?") }
        if let notes { sets.append("notes = ?") }
        guard !sets.isEmpty else { return }
        let sql = "UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id = ?"
        try db.run(sql) { st in
            var i = 1
            if let title { st.bind(i, title); i += 1 }
            if let notes { st.bind(i, notes); i += 1 }
            st.bind(i, id)
        }
        try reloadTasks()
    }

    func deleteTask(_ id: Int64) throws {
        try db.run("DELETE FROM tasks WHERE id = ?") { st in st.bind(1, id) }
        try reloadTasks()
    }

    /// Move a task to a lane at a target insertion index (nil = append).
    /// The index uses "insertion" semantics: the task is placed *between*
    /// `others[index-1]` and `others[index]`, where `others` is the target
    /// lane's task list **excluding the moved task itself** (same semantics
    /// as `addTask(at:)`, which inserts against a list that never contains
    /// the new task). If the task lands in the "Done" lane, stamp completedAt.
    func moveTask(_ id: Int64, toLane laneID: Int64, at index: Int? = nil) throws {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let doneLane = lane(named: "Done")?.id
        let wasDone = task.laneID == doneLane
        let isDone = laneID == doneLane

        if task.laneID == laneID {
            // Reorder within lane. `target` indexes the lane without the task.
            let laneTasks = laneTasks(laneID)
            guard let currentIndex = laneTasks.firstIndex(where: { $0.id == id }) else { return }
            let others = laneTasks.filter { $0.id != id }
            let target = index ?? others.count
            if target == currentIndex { return } // inserting before itself: no-op
            let pos: Double
            if others.isEmpty {
                pos = 1.0
            } else if target <= 0 {
                pos = others.first!.position - 1.0
            } else if target >= others.count {
                pos = others.last!.position + 1.0
            } else {
                pos = (others[target - 1].position + others[target].position) / 2
            }
            try db.run("UPDATE tasks SET position = ? WHERE id = ?") { st in
                st.bind(1, pos); st.bind(2, id)
            }
        } else {
            // Cross-lane move: park the task at the end first so position math
            // operates on the destination lane only.
            let pos = try newPosition(inLane: laneID, before: index)
            try db.run("UPDATE tasks SET lane_id = ?, position = ? WHERE id = ?") { st in
                st.bind(1, laneID); st.bind(2, pos); st.bind(3, id)
            }
        }

        // completedAt bookkeeping
        if isDone && !wasDone {
            try db.run("UPDATE tasks SET completed_at = ? WHERE id = ?") { st in
                st.bind(1, String(Date().timeIntervalSince1970)); st.bind(2, id)
            }
        } else if !isDone && wasDone {
            try db.run("UPDATE tasks SET completed_at = NULL WHERE id = ?") { st in
                st.bind(1, id)
            }
        }
        try reloadTasks()
    }

    // MARK: - Lane mutations

    @discardableResult
    func addLane(name: String) throws -> Lane {
        let pos = (lanes.map(\.position).max() ?? 0) + 1
        try db.run("INSERT INTO lanes (name, position) VALUES (?, ?)") { st in
            st.bind(1, name); st.bind(2, pos)
        }
        let id = db.lastInsertRowID
        try reloadAll()
        return lanes.first { $0.id == id }!
    }

    func renameLane(_ id: Int64, to name: String) throws {
        try db.run("UPDATE lanes SET name = ? WHERE id = ?") { st in
            st.bind(1, name); st.bind(2, id)
        }
        lanes = try db.query("SELECT * FROM lanes ORDER BY position", map: Self.lane(from:))
    }

    func deleteLane(_ id: Int64) throws {
        guard lanes.count > 1 else { return }
        try db.run("DELETE FROM lanes WHERE id = ?") { st in st.bind(1, id) }
        try reloadAll()
    }

    func moveLane(_ id: Int64, to index: Int) throws {
        guard let currentIndex = lanes.firstIndex(where: { $0.id == id }) else { return }
        let lane = lanes.remove(at: currentIndex)
        let clamped = min(max(index, 0), lanes.count)
        lanes.insert(lane, at: clamped)
        try db.transaction {
            for (i, lane) in lanes.enumerated() {
                try db.run("UPDATE lanes SET position = ? WHERE id = ?") { st in
                    st.bind(1, Double(i + 1)); st.bind(2, lane.id)
                }
            }
        }
        lanes = try db.query("SELECT * FROM lanes ORDER BY position", map: Self.lane(from:))
    }

    // MARK: - Jira persistence

    @discardableResult
    func addJiraAccount(name: String, email: String, baseURL: String, apiToken: String) throws -> JiraAccount {
        try db.run("INSERT INTO jira_accounts (name, email, base_url) VALUES (?, ?, ?)") { st in
            st.bind(1, name); st.bind(2, email); st.bind(3, baseURL)
        }
        let id = db.lastInsertRowID
        try KeychainStore.saveToken(apiToken, service: keychainService, forAccountID: id)
        jiraAccounts = try db.query("SELECT * FROM jira_accounts ORDER BY id", map: Self.account(from:))
        return jiraAccounts.first { $0.id == id }!
    }

    func updateJiraAccount(_ id: Int64, name: String? = nil, email: String? = nil, baseURL: String? = nil, apiToken: String? = nil) throws {
        var sets: [String] = []
        if let name { sets.append("name = ?") }
        if let email { sets.append("email = ?") }
        if let baseURL { sets.append("base_url = ?") }
        if !sets.isEmpty {
            let sql = "UPDATE jira_accounts SET \(sets.joined(separator: ", ")) WHERE id = ?"
            try db.run(sql) { st in
                var i = 1
                if let name { st.bind(i, name); i += 1 }
                if let email { st.bind(i, email); i += 1 }
                if let baseURL { st.bind(i, baseURL); i += 1 }
                st.bind(i, id)
            }
        }
        if let apiToken {
            try KeychainStore.saveToken(apiToken, service: keychainService, forAccountID: id)
        }
        jiraAccounts = try db.query("SELECT * FROM jira_accounts ORDER BY id", map: Self.account(from:))
    }

    func deleteJiraAccount(_ id: Int64) throws {
        try db.run("DELETE FROM jira_accounts WHERE id = ?") { st in st.bind(1, id) }
        try? KeychainStore.deleteToken(service: keychainService, forAccountID: id)
        try reloadAll()
    }

    func token(forAccount id: Int64) -> String? {
        try? KeychainStore.token(service: keychainService, forAccountID: id)
    }

    @discardableResult
    func addJiraSpace(accountID: Int64, name: String, projectKey: String, jql: String?, boardID: Int? = nil) throws -> JiraSpace {
        try db.run("INSERT INTO jira_spaces (account_id, name, project_key, jql, board_id) VALUES (?, ?, ?, ?, ?)") { st in
            st.bind(1, accountID)
            st.bind(2, name)
            st.bind(3, projectKey)
            if let jql { st.bind(4, jql) } else { st.bindNull(4) }
            if let boardID { st.bind(5, Int64(boardID)) } else { st.bindNull(5) }
        }
        let id = db.lastInsertRowID
        jiraSpaces = try db.query("SELECT * FROM jira_spaces ORDER BY id", map: Self.space(from:))
        return jiraSpaces.first { $0.id == id }!
    }

    func deleteJiraSpace(_ id: Int64) throws {
        try db.run("DELETE FROM jira_spaces WHERE id = ?") { st in st.bind(1, id) }
        jiraSpaces = try db.query("SELECT * FROM jira_spaces ORDER BY id", map: Self.space(from:))
    }

    // MARK: - GitHub accounts & repos

    @discardableResult
    func addGitHubAccount(name: String, baseURL: String, login: String, token: String) throws -> GitHubAccount {
        try db.run("INSERT INTO github_accounts (name, base_url, login) VALUES (?, ?, ?)") { st in
            st.bind(1, name); st.bind(2, baseURL); st.bind(3, login)
        }
        let id = db.lastInsertRowID
        try KeychainStore.saveToken(token, service: keychainService, kind: "github", forAccountID: id)
        githubAccounts = try db.query("SELECT * FROM github_accounts ORDER BY id", map: Self.gitHubAccount(from:))
        return githubAccounts.first { $0.id == id }!
    }

    func deleteGitHubAccount(_ id: Int64) throws {
        try db.run("DELETE FROM github_accounts WHERE id = ?") { st in st.bind(1, id) }
        try? KeychainStore.deleteToken(service: keychainService, kind: "github", forAccountID: id)
        try reloadAll()
    }

    func githubToken(forAccount id: Int64) -> String? {
        try? KeychainStore.token(service: keychainService, kind: "github", forAccountID: id)
    }

    @discardableResult
    func addGitHubRepo(accountID: Int64, name: String, owner: String, repo: String) throws -> GitHubRepo {
        try db.run("INSERT INTO github_repos (account_id, name, owner, repo) VALUES (?, ?, ?, ?)") { st in
            st.bind(1, accountID)
            st.bind(2, name)
            st.bind(3, owner)
            st.bind(4, repo)
        }
        let id = db.lastInsertRowID
        githubRepos = try db.query("SELECT * FROM github_repos ORDER BY id", map: Self.gitHubRepo(from:))
        return githubRepos.first { $0.id == id }!
    }

    func deleteGitHubRepo(_ id: Int64) throws {
        try db.run("DELETE FROM github_repos WHERE id = ?") { st in st.bind(1, id) }
        githubRepos = try db.query("SELECT * FROM github_repos ORDER BY id", map: Self.gitHubRepo(from:))
    }

    // MARK: - Board cache (cache-then-network payloads)

    func cachedData(for key: String) -> (data: Data, fetchedAt: Date)? {
        let rows: [(Data, Date)]? = try? db.query(
            "SELECT data, fetched_at FROM board_cache WHERE key = ?",
            { st in st.bind(1, key) },
            map: { st in
                (st.data("data") ?? Data(), Date(timeIntervalSince1970: st.double("fetched_at")))
            }
        )
        guard let row = rows?.first, !row.0.isEmpty else { return nil }
        return (row.0, row.1)
    }

    func storeCachedData(_ data: Data, for key: String) {
        try? db.run("INSERT OR REPLACE INTO board_cache (key, data, fetched_at) VALUES (?, ?, ?)") { st in
            st.bind(1, key)
            st.bind(2, data)
            st.bind(3, Date().timeIntervalSince1970)
        }
    }
}
extension TodoStore: BoardCaching {}
