import Foundation

/// Polls every account's mentions in the background (at launch, then every
/// 5 minutes) to power the sidebar unread badges. Reuses the mentions
/// models themselves so it inherits the exact same cache-then-network logic
/// (fresh caches skip the network round-trip) and the same read-key
/// conventions.
///
/// Publishes the raw mention keys per account — not the unread counts — so
/// the UI subtracts the (published, instantly-updating) read set at render
/// time. Opening a mention from the page therefore updates the badge
/// immediately, without waiting for the next poll.
@MainActor
final class MentionsTracker: ObservableObject {
    /// Jira account id → mention issue keys ("TAP-123").
    @Published private(set) var jiraMentionKeys: [Int64: Set<String>] = [:]
    /// GitHub account id → mention keys ("owner/repo#42").
    @Published private(set) var githubMentionKeys: [Int64: Set<String>] = [:]

    /// Test seam: inject keys as if a previous tick had seen them.
    var jiraMentionKeysForTesting: [Int64: Set<String>] {
        get { jiraMentionKeys }
        set { jiraMentionKeys = newValue }
    }

    var githubMentionKeysForTesting: [Int64: Set<String>] {
        get { githubMentionKeys }
        set { githubMentionKeys = newValue }
    }

    /// One pass over all accounts. Cheap by design: models consult their
    /// cache first and skip the network when the cached snapshot is under
    /// a minute old.
    func tick(store: TodoStore, jiraTokens: [Int64: String], githubTokens: [Int64: String]) async {
        var jira: [Int64: Set<String>] = [:]
        for account in store.jiraAccounts {
            // The mentions page shows the account's first space; the badge
            // must match exactly what that page would show.
            guard let space = store.jiraSpaces.first(where: { $0.accountID == account.id }),
                  let token = jiraTokens[account.id] else { continue }
            let model = MentionsModel(account: account, space: space, token: token, cache: store)
            await model.load()
            jira[account.id] = Set(model.mentioned.map(\.key))
        }
        jiraMentionKeys = jira

        var github: [Int64: Set<String>] = [:]
        for account in store.githubAccounts {
            let repos = store.githubRepos.filter { $0.accountID == account.id }
            guard !repos.isEmpty, let token = githubTokens[account.id] else { continue }
            let model = GitHubMentionsModel(account: account, repos: repos, token: token, cache: store)
            await model.load()
            github[account.id] = Set(model.mentioned.map(\.readKey))
        }
        githubMentionKeys = github
    }
}