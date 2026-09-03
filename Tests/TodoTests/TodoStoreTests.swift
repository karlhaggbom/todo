import Testing
import Foundation
@testable import Todo

/// TodoStore: seeded lanes, task CRUD, ordering math, completedAt
/// bookkeeping, lane CRUD, and persistence across store instances.
@Suite(.serialized) final class TodoStoreTests {
    private func makeStore() -> TodoStore {
        // Each test gets a private on-disk database (WAL mode requires a file)
        // and a private Keychain namespace, so tests never read or clobber the
        // user's real keychain items (which they also cannot delete — items
        // created by the signed app are ACL-protected from test binaries).
        TodoStore(
            databasePath: "\(NSTemporaryDirectory())/todo-store-test-\(UUID().uuidString).sqlite3",
            keychainService: "todo.tests.\(UUID().uuidString)"
        )
    }

    private func addTasks(_ store: TodoStore, titles: [String], lane: Int64? = nil) throws {
        for t in titles {
            _ = try store.addTask(title: t, laneID: lane)
        }
    }

    private func titles(in store: TodoStore, lane: Lane) -> [String] {
        store.laneTasks(lane.id).map(\.title)
    }

    // MARK: Seeding

    @Test func seedCreatesBacklogDoingDoneInOrder() {
        let store = makeStore()
        #expect(store.lanes.map(\.name) == ["Backlog", "Doing", "Done"])
        #expect(store.lanes.map(\.position) == [0.0, 1.0, 2.0])
    }

    // MARK: Task CRUD

    @Test func addTaskAppendsWithAscendingPositionsInTargetLane() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["first", "second", "third"], lane: backlog.id)

        let tasks = store.laneTasks(backlog.id)
        #expect(titles(in: store, lane: backlog) == ["first", "second", "third"])
        let positions = tasks.map(\.position)
        #expect(positions == positions.sorted(), "positions must be monotonically increasing")
        #expect(positions[1] > positions[0])
        #expect(positions[2] < 100, "positions stay in a healthy numeric range")
    }

    @Test func addTaskAtIndexInsertsBetweenNeighborsNotAtEnd() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B"], lane: backlog.id)

        let inserted = try store.addTask(title: "middle", laneID: backlog.id, at: 1)
        #expect(abs(inserted.position - 1.5) < 0.0001, "midpoint between 1.0 and 2.0")
        #expect(titles(in: store, lane: backlog) == ["A", "middle", "B"])
    }

    @Test func addTaskAtIndexZeroInsertsBeforeFirst() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A"], lane: backlog.id)

        _ = try store.addTask(title: "top", laneID: backlog.id, at: 0)
        #expect(titles(in: store, lane: backlog) == ["top", "A"])
    }

    @Test func updateTaskPersistsAcrossStoreReopen() throws {
        let path = "\(NSTemporaryDirectory())/todo-store-persist-\(UUID().uuidString).sqlite3"
        let taskID: Int64
        do {
            let store = TodoStore(databasePath: path)
            let backlog = store.lanes[0]
            taskID = try store.addTask(title: "original", notes: "old", laneID: backlog.id).id
            try store.updateTask(taskID, title: "renamed", notes: "updated")
        }
        let reopened = TodoStore(databasePath: path)
        let task = reopened.tasks.first { $0.id == taskID }
        #expect(task?.title == "renamed", "title must survive reopen")
        #expect(task?.notes == "updated", "notes must survive reopen")
        #expect(task?.completedAt == nil)
    }

    @Test func deleteTaskRemovesOnlyTargetTask() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["keep", "drop", "also-keep"], lane: backlog.id)
        let dropID = store.tasks.first { $0.title == "drop" }!.id

        try store.deleteTask(dropID)

        #expect(titles(in: store, lane: backlog) == ["keep", "also-keep"], "other tasks must be untouched")
        #expect(!store.tasks.contains { $0.id == dropID })
    }

    // MARK: Moves

    @Test func moveTaskToOtherLaneAppendsAtEndOfDestination() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        let doing = store.lanes[1]
        try addTasks(store, titles: ["a1", "a2"], lane: backlog.id)
        try addTasks(store, titles: ["d1"], lane: doing.id)
        let a1 = store.tasks.first { $0.title == "a1" }!

        try store.moveTask(a1.id, toLane: doing.id)

        #expect(titles(in: store, lane: backlog) == ["a2"])
        #expect(titles(in: store, lane: doing) == ["d1", "a1"], "cross-lane move appends by default")
    }

    @Test func moveTaskToSameLaneSameIndexIsNoOp() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["a", "b", "c"], lane: backlog.id)
        let b = store.tasks.first { $0.title == "b" }!
        let positionBefore = b.position

        try store.moveTask(b.id, toLane: backlog.id, at: 1)

        #expect(titles(in: store, lane: backlog) == ["a", "b", "c"])
        #expect(store.tasks.first { $0.id == b.id }?.position == positionBefore)
    }

    @Test func moveTaskWithinLaneDownwardShiftsFollowingTasks() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B", "C"], lane: backlog.id)
        let a = store.tasks.first { $0.title == "A" }!

        try store.moveTask(a.id, toLane: backlog.id, at: 3)

        #expect(titles(in: store, lane: backlog) == ["B", "C", "A"])
    }

    @Test func moveTaskDownByOneFromFirstDoesNotCrash() throws {
        // Regression: this used to index laneTasks[target - 2] = [-1] and trap.
        // Semantics: `at:` is an insertion index in the lane EXCLUDING the
        // moved task, so at: 1 = insert after B.
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B", "C"], lane: backlog.id)
        let a = store.tasks.first { $0.title == "A" }!

        try store.moveTask(a.id, toLane: backlog.id, at: 1)

        #expect(titles(in: store, lane: backlog) == ["B", "A", "C"])
    }

    @Test func moveTaskDownByOneFromMiddleReordersNeighbors() throws {
        // Regression: used to be a silent no-op (midpoint of its own slot).
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B", "C"], lane: backlog.id)
        let b = store.tasks.first { $0.title == "B" }!

        // Insertion index 2 = between C and the end (after C, since others = [A, C]).
        try store.moveTask(b.id, toLane: backlog.id, at: 2)

        #expect(titles(in: store, lane: backlog) == ["A", "C", "B"])
    }

    @Test func moveTaskUpByOneToTop() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B", "C"], lane: backlog.id)
        let c = store.tasks.first { $0.title == "C" }!

        // Insertion index 0 = before A (others = [A, B]).
        try store.moveTask(c.id, toLane: backlog.id, at: 0)

        #expect(titles(in: store, lane: backlog) == ["C", "A", "B"])
    }

    @Test func moveTaskInsertBeforeItselfIsNoOp() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try addTasks(store, titles: ["A", "B"], lane: backlog.id)
        let b = store.tasks.first { $0.title == "B" }!
        let positionBefore = b.position

        try store.moveTask(b.id, toLane: backlog.id, at: 1)

        #expect(titles(in: store, lane: backlog) == ["A", "B"])
        #expect(store.tasks.first { $0.id == b.id }?.position == positionBefore,
                "inserting a task before itself must not rewrite its position")
    }

    @Test func moveTaskToOtherLaneAtExplicitInsertionIndex() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        let doing = store.lanes[1]
        try addTasks(store, titles: ["a1"], lane: backlog.id)
        try addTasks(store, titles: ["d1", "d2"], lane: doing.id)
        let a1 = store.tasks.first { $0.title == "a1" }!

        // Insertion index 1 = between d1 and d2.
        try store.moveTask(a1.id, toLane: doing.id, at: 1)

        #expect(titles(in: store, lane: doing) == ["d1", "a1", "d2"])
        #expect(titles(in: store, lane: backlog) == [])
    }

    @Test func moveTaskIntoDoneLaneStampsCompletedAt() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        let done = store.lane(named: "Done")!
        let task = try store.addTask(title: "finish me", laneID: backlog.id)

        try store.moveTask(task.id, toLane: done.id)

        let moved = store.tasks.first { $0.id == task.id }!
        #expect(moved.completedAt != nil, "moving into Done must stamp completedAt")
        #expect(moved.laneID == done.id)
    }

    @Test func moveTaskOutOfDoneLaneClearsCompletedAt() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        let done = store.lane(named: "Done")!
        let task = try store.addTask(title: "reopen me", laneID: done.id)
        try store.moveTask(task.id, toLane: done.id) // ensure stamped
        #expect(store.tasks.first { $0.id == task.id }?.completedAt != nil)

        try store.moveTask(task.id, toLane: backlog.id)

        let moved = store.tasks.first { $0.id == task.id }!
        #expect(moved.completedAt == nil, "leaving Done must clear completedAt")
    }

    // MARK: Lanes

    @Test func addLaneAppendsAfterExistingLanes() throws {
        let store = makeStore()
        let lane = try store.addLane(name: "Blocked")
        #expect(store.lanes.map(\.name) == ["Backlog", "Doing", "Done", "Blocked"])
        #expect(abs(lane.position - 3.0) < 0.0001)
    }

    @Test func deleteLaneCascadesItsTasks() throws {
        let store = makeStore()
        let extra = try store.addLane(name: "Temp")
        let task = try store.addTask(title: "in temp", laneID: extra.id)
        let otherTask = try store.addTask(title: "in backlog", laneID: store.lanes[0].id)

        try store.deleteLane(extra.id)

        #expect(!store.lanes.contains { $0.id == extra.id })
        #expect(!store.tasks.contains { $0.id == task.id }, "tasks in a deleted lane must cascade")
        #expect(store.tasks.contains { $0.id == otherTask.id }, "tasks elsewhere must survive")
    }

    @Test func deleteLaneRefusedWhenLastLaneRemains() throws {
        let store = makeStore()
        try store.deleteLane(store.lanes[2].id) // Done
        try store.deleteLane(store.lanes[1].id) // Doing
        #expect(store.lanes.count == 1)

        try store.deleteLane(store.lanes[0].id)

        #expect(store.lanes.count == 1, "the last lane must never be deletable")
    }

    @Test func renameLaneUpdatesNameForQueriesAndLookups() throws {
        let store = makeStore()
        let backlog = store.lanes[0]
        try store.renameLane(backlog.id, to: "Someday")

        #expect(store.lanes[0].name == "Someday")
        #expect(store.lane(named: "Someday")?.id == backlog.id)
        #expect(store.lane(named: "Backlog") == nil, "old name must no longer resolve")
    }

    @Test func moveLaneReordersAndRepersistPositions() throws {
        // Regression: used to force-unwrap a lane it had just removed.
        let path = "\(NSTemporaryDirectory())/todo-store-movelane-\(UUID().uuidString).sqlite3"
        let store = TodoStore(databasePath: path)
        let done = store.lanes[2]

        try store.moveLane(done.id, to: 0)

        #expect(store.lanes.map(\.name) == ["Done", "Backlog", "Doing"])
        #expect(store.lanes.map(\.position) == [1.0, 2.0, 3.0])

        // Survives reopen: positions were written to disk.
        let reopened = TodoStore(databasePath: path)
        #expect(reopened.lanes.map(\.name) == ["Done", "Backlog", "Doing"])
    }

    // MARK: Jira persistence

    @Test func addJiraAccountAndSpacePersistAndTokenRoundTrips() throws {
        let store = makeStore()
        let account = try store.addJiraAccount(
            name: "Work", email: "me@example.com",
            baseURL: "https://example.atlassian.net", apiToken: "tok-abc123"
        )
        defer { try? store.deleteJiraAccount(account.id) }

        #expect(store.jiraAccounts.first?.name == "Work")
        #expect(store.token(forAccount: account.id) == "tok-abc123", "API token must round-trip through the Keychain")

        let space = try store.addJiraSpace(
            accountID: account.id, name: "Team", projectKey: "TEAM",
            jql: "project = TEAM AND sprint in openSprints()"
        )
        #expect(store.jiraSpaces.first?.id == space.id)
        #expect(store.jiraSpaces.first?.projectKey == "TEAM")

        try store.deleteJiraSpace(space.id)
        #expect(store.jiraSpaces.isEmpty, "deleted space must be gone")
    }

    @Test func deleteJiraAccountRemovesAccountAndItsSpaces() throws {
        let store = makeStore()
        let account = try store.addJiraAccount(
            name: "Work", email: "me@example.com",
            baseURL: "https://example.atlassian.net", apiToken: "tok-xyz"
        )
        _ = try store.addJiraSpace(accountID: account.id, name: "Team", projectKey: "TEAM", jql: nil)

        try store.deleteJiraAccount(account.id)

        #expect(store.jiraAccounts.isEmpty, "account must be gone")
        #expect(store.jiraSpaces.isEmpty, "spaces must cascade with their account")
        #expect(store.token(forAccount: account.id) == nil, "keychain token must be deleted with the account")
    }

    @Test func softDeletedTokenReadsAsMissing() throws {
        // When a hard delete is ACL-denied (item owned by an earlier build
        // under ad-hoc signing), deleteToken falls back to clearing the
        // secret to whitespace; such items must read as missing.
        let store = makeStore()
        let account = try store.addJiraAccount(
            name: "Work", email: "me@example.com",
            baseURL: "https://example.atlassian.net", apiToken: "real-token"
        )
        try KeychainStore.saveToken(" ", service: store.keychainService, forAccountID: account.id)
        #expect(store.token(forAccount: account.id) == nil, "whitespace-only secret must read as missing")

        // And re-saving a real token on top of a cleared item round-trips.
        try KeychainStore.saveToken("back", service: store.keychainService, forAccountID: account.id)
        #expect(store.token(forAccount: account.id) == "back")
    }
}