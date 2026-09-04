import Foundation

/// Polls every account's activity feed in the background (at launch, then
/// every 5 minutes) to power the sidebar unread badges. Reuses the activity
/// models themselves so it inherits the exact same cache-then-network logic
/// (fresh caches skip the network round-trip) and the same read-key
/// conventions.
///
/// Publishes the raw activity read-keys per account — not the unread counts
/// — so the UI subtracts the (published, instantly-updating) read set at
/// render time. Opening an activity row from the page therefore updates the
/// badge immediately, without waiting for the next poll. Because keys are
/// per-activity ("TAP-1@<timestamp>"), a new comment on an already-read
/// issue counts as unread again.
@MainActor
final class ActivityTracker: ObservableObject {
    /// Jira account id → activity read-keys ("TAP-123@<timestamp>").
    @Published private(set) var jiraActivityKeys: [Int64: Set<String>] = [:]
    /// GitHub account id → activity read-keys ("owner/repo#42@<timestamp>").
    @Published private(set) var githubActivityKeys: [Int64: Set<String>] = [:]

    /// Test seam: inject keys as if a previous tick had seen them.
    var jiraActivityKeysForTesting: [Int64: Set<String>] {
        get { jiraActivityKeys }
        set { jiraActivityKeys = newValue }
    }

    var githubActivityKeysForTesting: [Int64: Set<String>] {
        get { githubActivityKeys }
        set { githubActivityKeys = newValue }
    }

    /// One pass over all accounts. Cheap by design: models consult their
    /// cache first and skip the network when the cached snapshot is under
    /// a minute old.
    func tick(store: TodoStore, jiraTokens: [Int64: String], githubTokens: [Int64: String]) async {
        var jira: [Int64: Set<String>] = [:]
        for account in store.jiraAccounts {
            // The activity page shows the account's first space; the badge
            // must match exactly what that page would show.
            guard let space = store.jiraSpaces.first(where: { $0.accountID == account.id }),
                  let token = jiraTokens[account.id] else { continue }
            let model = ActivityModel(account: account, space: space, token: token, cache: store)
            await model.load()
            jira[account.id] = Set(model.activity.map(\.readKey))
        }
        jiraActivityKeys = jira

        var github: [Int64: Set<String>] = [:]
        for account in store.githubAccounts {
            let repos = store.githubRepos.filter { $0.accountID == account.id }
            guard !repos.isEmpty, let token = githubTokens[account.id] else { continue }
            let model = GitHubActivityModel(account: account, repos: repos, token: token, cache: store)
            await model.load()
            github[account.id] = Set(model.activity.map(\.readKey))
        }
        githubActivityKeys = github
    }
}