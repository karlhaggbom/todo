import Testing
import Foundation
@testable import Todo

/// AppPreferences (UserDefaults-backed UI toggles) and the background
/// mentions tracker that powers the sidebar badges.
@Suite(.serialized) final class PreferencesAndTrackerTests {

    // MARK: AppPreferences

    @Test func mineOnlyDefaultsTrueAndPersists() {
        let id = Int64.random(in: 100_000...999_999)
        defer {
            UserDefaults.standard.removeObject(forKey: "jira-mineOnly-\(id)")
        }
        #expect(AppPreferences.mineOnly(spaceID: id) == true)

        AppPreferences.setMineOnly(false, spaceID: id)
        #expect(AppPreferences.mineOnly(spaceID: id) == false)

        // Distinct spaces are independent.
        AppPreferences.setMineOnly(false, spaceID: id)
        #expect(AppPreferences.mineOnly(spaceID: id + 1) == true)
    }

    @Test func showReadDefaultsFalseAndPersists() {
        let scope = "test-scope-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "showRead-\(scope)")
        }
        #expect(AppPreferences.showRead(scope: scope) == false)

        AppPreferences.setShowRead(true, scope: scope)
        #expect(AppPreferences.showRead(scope: scope) == true)
    }

    // MARK: ActivityTracker

    /// A tick with accounts that have no tokens (and no network) must
    /// complete without throwing, skip those accounts, and — crucially —
    /// drop keys for accounts that disappeared since the last tick.
    @MainActor
    @Test func trackerTickIsNetworkSafeAndClearsStaleAccounts() async throws {
        let store = TodoStore(
            databasePath: "\(NSTemporaryDirectory())/todo-tracker-test-\(UUID().uuidString).sqlite3",
            keychainService: "todo.tests.\(UUID().uuidString)"
        )
        _ = try store.addJiraAccount(
            name: "Test", email: "e@x.com", baseURL: "https://x.example.com", apiToken: "dummy"
        )
        guard let account = store.jiraAccounts.first else {
            Issue.record("account not created")
            return
        }
        _ = try store.addJiraSpace(
            accountID: account.id, name: "Space", projectKey: "TST",
            jql: nil, boardID: nil
        )

        let tracker = ActivityTracker()
        // Simulate a previous tick that saw mentions for a long-gone account.
        tracker.jiraActivityKeysForTesting = [999: ["TST-1"]]
        tracker.githubActivityKeysForTesting = [999: ["org/repo#1"]]

        // No tokens → every account is skipped; no network happens.
        await tracker.tick(store: store, jiraTokens: [:], githubTokens: [:])

        #expect(tracker.jiraActivityKeys.isEmpty)
        #expect(tracker.githubActivityKeys.isEmpty)
    }
}