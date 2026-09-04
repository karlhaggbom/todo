import Foundation

// MARK: - GitHub board lanes

/// GitHub issues don't have arbitrary statuses — the board uses the three
/// intrinsic lifecycle lanes: Open, Completed, Not Planned.
struct GitHubLane: Identifiable, Equatable {
    let id: String
    let name: String

    static let open = GitHubLane(id: "open", name: "Open")
    static let completed = GitHubLane(id: "completed", name: "Completed")
    static let notPlanned = GitHubLane(id: "not_planned", name: "Not Planned")

    static let all = [GitHubLane.open, GitHubLane.completed, GitHubLane.notPlanned]
}

// MARK: - GitHub board model

/// Persisted GitHub board snapshot for cache-then-network loading.
struct CachedGitHubBoard: Codable {
    let issues: [GitHubIssue]
    let fetchedAt: Date
}

final class GitHubBoardModel: ObservableObject, KeyboardNavigable {
    let repo: GitHubRepo
    let account: GitHubAccount
    let client: GitHubClient
    let cache: BoardCaching?
    let lanes = GitHubLane.all

    @Published private(set) var issues: [GitHubIssue] = []
    @Published var lastError: String?
    @Published private(set) var isLoading = false
    @Published var lastUpdated: Date?
    /// True while the visible content comes from the cache and the
    /// network refresh is still in flight.
    @Published private(set) var showingCached = false

    /// Active board filter (synced from AppModel.filterText by the view).
    @Published var filterText: String = ""
    /// "My tickets only": pre-selected; filters each lane to issues assigned
    /// to the account's login. Client-side, so toggling is instant.
    @Published var mineOnly = true

    private var cacheKey: String { "github-board-\(repo.id)" }

    init(account: GitHubAccount, repo: GitHubRepo, token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.repo = repo
        self.cache = cache
        self.client = GitHubClient(credentials: .init(
            baseURL: account.baseURL,
            token: token
        ))
    }

    // MARK: Loading

    @MainActor
    func load() async {
        await load(force: false)
    }

    /// The refresh button forces past the cache-freshness shortcut.
    @MainActor
    func refresh() async {
        await load(force: true)
    }

    @MainActor
    func load(force: Bool = false) async {
        Diag.log.info("github load start repo=\(self.repo.owner)/\(self.repo.repo, privacy: .public) force=\(force, privacy: .public)")
        // Cache-first: publish the last successful fetch immediately so the
        // board is usable while the network request is in flight.
        var cacheIsFresh = false
        if issues.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode(CachedGitHubBoard.self, from: entry.data) {
            issues = snapshot.issues
            lastUpdated = entry.fetchedAt
            showingCached = true
            cacheIsFresh = Date().timeIntervalSince(entry.fetchedAt) < 60
            Diag.log.info("github published cached snapshot issues=\(snapshot.issues.count, privacy: .public) fresh=\(cacheIsFresh, privacy: .public)")
        }
        // Cache is under a minute old: skip the network round-trip.
        if !force, cacheIsFresh {
            Diag.log.info("github load skipped: cache < 60s old")
            isLoading = false
            return
        }
        isLoading = true
        lastError = nil
        do {
            let fetched = try await client.issues(owner: repo.owner, repo: repo.repo)
            issues = fetched
            lastUpdated = Date()
            showingCached = false
            if let cache,
               let payload = try? JSONEncoder().encode(
                   CachedGitHubBoard(issues: fetched, fetchedAt: lastUpdated!)
               ) {
                cache.storeCachedData(payload, for: cacheKey)
            }
            Diag.log.info("github loaded issues=\(fetched.count)")
        } catch {
            lastError = "\(error.localizedDescription)"
            Diag.log.error("github load failed: \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
    }

    // MARK: Board structure

    /// Apply a successful server edit: the PATCH returns the updated issue,
    /// so the server-rendered copy replaces the board copy in place.
    @MainActor
    func applyEdit(_ updated: GitHubIssue) {
        guard let idx = issues.firstIndex(where: { $0.number == updated.number }) else { return }
        issues[idx] = updated
    }

    func issues(inLane laneID: String) -> [GitHubIssue] {
        let base = issues.filter { $0.laneID == laneID }
        let scoped = mineOnly
            ? base.filter { ($0.assignees ?? []).contains { $0.login == account.login } }
            : base
        let f = filterText
        guard !f.isEmpty else { return scoped }
        let int = Int(f)
        return scoped.filter {
            $0.title.localizedCaseInsensitiveContains(f) ||
            (int != nil && $0.number == int)
        }
    }

    /// Transition an issue to another lane (open / completed / not
    /// planned). Optimistic: the card flips lane instantly, the server
    /// response replaces it on success, and the move reverts on failure.
    @MainActor
    func transition(issueNumber: Int, toLane laneID: String) async -> Bool {
        let state: String
        let stateReason: String?
        switch laneID {
        case GitHubLane.completed.id:
            state = "closed"; stateReason = "completed"
        case GitHubLane.notPlanned.id:
            state = "closed"; stateReason = "not_planned"
        default:
            state = "open"; stateReason = nil
        }
        guard let idx = issues.firstIndex(where: { $0.number == issueNumber }) else { return false }
        let previous = issues[idx]
        issues[idx] = GitHubIssue(
            number: previous.number, title: previous.title, body: previous.body,
            state: state, stateReason: stateReason, htmlURL: previous.htmlURL,
            updatedAt: previous.updatedAt, labels: previous.labels,
            assignees: previous.assignees, pullRequest: previous.pullRequest
        )
        do {
            let updated = try await client.patchIssue(
                owner: repo.owner, repo: repo.repo, number: issueNumber,
                state: state, stateReason: stateReason
            )
            if let i = issues.firstIndex(where: { $0.number == issueNumber }) {
                issues[i] = updated
            }
            return true
        } catch {
            if let i = issues.firstIndex(where: { $0.number == issueNumber }) {
                issues[i] = previous
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @MainActor
    /// `accepted` mirrors the HTTP status: true means the server stored the
    /// comment. `created` is the server-rendered replacement for the local
    /// placeholder, or nil if the response didn't decode (keep placeholder).
    func addComment(issueNumber: Int, body: String) async -> (accepted: Bool, created: GitHubComment?) {
        do {
            let created = try await client.addComment(
                owner: repo.owner, repo: repo.repo, number: issueNumber, body: body
            )
            return (true, created)
        } catch {
            Diag.log.error("github addComment failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return (false, nil)
        }
    }

    /// Insert a freshly created issue at the top of the board.
    func insertCreated(_ issue: GitHubIssue) {
        issues.insert(issue, at: 0)
    }

    func editComment(id: Int, body: String) async -> Bool {
        do {
            _ = try await client.updateComment(
                owner: repo.owner, repo: repo.repo, id: id, body: body
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func deleteComment(id: Int) async -> Bool {
        do {
            try await client.deleteComment(owner: repo.owner, repo: repo.repo, id: id)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: KeyboardNavigable

    var navLaneCount: Int { lanes.count }

    func navItemCount(lane: Int) -> Int {
        guard lanes.indices.contains(lane) else { return 0 }
        return issues(inLane: lanes[lane].id).count
    }

    func navMove(lane: Int, item: Int) -> Bool {
        // Selection is visual; nothing to persist here.
        true
    }

    func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool {
        // H/L keys: transition the issue to the adjacent lane.
        guard toLaneDelta != 0 else { return false }
        let target = lane + toLaneDelta
        guard lanes.indices.contains(target),
              lanes.indices.contains(lane),
              let issue = issues(inLane: lanes[lane].id)[safe: item] else { return false }
        let laneID = lanes[target].id
        Task { @MainActor in _ = await self.transition(issueNumber: issue.number, toLane: laneID) }
        return true
    }

    func navOpenDetail(lane: Int, item: Int) {}
    func navBeginRename(lane: Int, item: Int) {}
}

// MARK: - GitHub mentions model

/// Issues mentioning the signed-in user across an account's repos.
final class GitHubActivityModel: ObservableObject {
    let account: GitHubAccount
    let client: GitHubClient
    let repos: [GitHubRepo]
    let token: String
    let cache: BoardCaching?

    private var cacheKey: String { "github-activity-\(account.id)" }

    /// The activity feed, newest first: mentions, issues/PRs assigned to
    /// the user, PRs awaiting their review, and others' comments/changes on
    /// their issues. One entry per issue, with the most recent reason.
    @Published private(set) var activity: [GitHubActivityEntry] = []
    @Published var lastError: String?
    @Published private(set) var isLoading = false
    @Published var lastUpdated: Date?
    /// True while the visible list comes from the cache and the network
    /// refresh is still in flight (same semantics as the boards).
    @Published private(set) var showingCached = false

    init(account: GitHubAccount, repos: [GitHubRepo], token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.repos = repos
        self.token = token
        self.cache = cache
        self.client = GitHubClient(credentials: .init(
            baseURL: account.baseURL,
            token: token
        ))
    }

    @MainActor
    func load() async {
        await load(force: false)
    }

    /// The refresh button forces past the cache-freshness shortcut.
    @MainActor
    func load(force: Bool) async {
        // Cache-first (same policy as boards): publish the cached snapshot
        // immediately, then refresh in the background.
        var cacheIsFresh = false
        if activity.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode([GitHubActivityEntry].self, from: entry.data) {
            activity = Self.sorted(snapshot)
            lastUpdated = entry.fetchedAt
            showingCached = true
            cacheIsFresh = Date().timeIntervalSince(entry.fetchedAt) < 60
        }
        // Cache is under a minute old: skip the network round-trip.
        if !force, cacheIsFresh {
            Diag.log.info("github activity load skipped: cache < 60s old")
            isLoading = false
            return
        }
        isLoading = true
        lastError = nil
        do {
            var byId: [String: GitHubActivityEntry] = [:]
            for repo in repos {
                // Three searches in parallel: mentions, assignments
                // (issues + PRs), and PRs awaiting my review.
                async let mentionsTask = client.issuesMentioning(
                    owner: repo.owner, repo: repo.repo, login: account.login
                )
                async let assignedTask = client.issuesAssigned(
                    owner: repo.owner, repo: repo.repo, login: account.login
                )
                async let reviewTask = client.prsReviewRequested(
                    owner: repo.owner, repo: repo.repo, login: account.login
                )
                let (mentions, assigned, reviews) = try await (mentionsTask, assignedTask, reviewTask)
                for issue in mentions {
                    byId["\(repo.id)-\(issue.number)"] = GitHubActivityEntry(
                        reason: .mention, repo: repo, issue: issue,
                        activityAt: issue.updatedAt ?? "", actor: nil
                    )
                }
                for pr in reviews {
                    let entry = GitHubActivityEntry(
                        reason: .reviewRequested, repo: repo, issue: pr,
                        activityAt: pr.updatedAt ?? "", actor: nil
                    )
                    byId[entry.id] = byId[entry.id].map { GitHubActivityEntry.newest($0, entry) } ?? entry
                }
                for issue in assigned {
                    if let entry = await assignedEntry(issue, in: repo) {
                        byId[entry.id] = byId[entry.id].map { GitHubActivityEntry.newest($0, entry) } ?? entry
                    }
                }
            }
            let fresh = Self.sorted(Array(byId.values))
            activity = fresh
            lastUpdated = Date()
            showingCached = false
            if let cache, let data = try? JSONEncoder().encode(fresh) {
                cache.storeCachedData(data, for: cacheKey)
            }
            Diag.log.info("github activity loaded entries=\(fresh.count, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Analyze one issue/PR assigned to me: someone else's comment, their
    /// change, or — with no other activity — the assignment itself.
    /// Returns nil when the only activity is my own (self-assignment,
    /// my own edits): own updates must never create feed entries.
    private func assignedEntry(_ issue: GitHubIssue, in repo: GitHubRepo) async -> GitHubActivityEntry? {
        let comments = (try? await client.comments(owner: repo.owner, repo: repo.repo, number: issue.number)) ?? []
        let events = (try? await client.issueEvents(owner: repo.owner, repo: repo.repo, number: issue.number)) ?? []
        let myLogin = account.login.lowercased()
        func isMe(_ login: String?) -> Bool { login?.lowercased() == myLogin }

        // Comments by someone else.
        let otherComments = comments.filter { !isMe($0.user.login) }
        if let latest = Self.latest(otherComments, by: { $0.createdAt }) {
            return GitHubActivityEntry(
                reason: .comment, repo: repo, issue: issue,
                activityAt: latest.createdAt, actor: latest.user.login
            )
        }
        // Meaningful changes by someone else (bots excluded to keep CI
        // sync noise out of the feed).
        let otherChanges = events.filter { e in
            guard Self.changeEvents.contains(e.event),
                  let actor = e.actor?.login,
                  !isMe(actor) else { return false }
            return !actor.hasSuffix("[bot]") && actor != "github-actions"
        }
        if let latest = Self.latest(otherChanges, by: { $0.createdAt }) {
            return GitHubActivityEntry(
                reason: .change, repo: repo, issue: issue,
                activityAt: latest.createdAt, actor: latest.actor?.login
            )
        }
        // Nothing by anyone else: the assignment itself is the activity —
        // unless the last assigned-to-me event was performed by me.
        let assignedToMe = events.filter { $0.event == "assigned" && $0.assignee?.login.lowercased() == myLogin }
        if let last = Self.latest(assignedToMe, by: { $0.createdAt }), isMe(last.actor?.login) {
            return nil // self-assigned: my own action, not activity
        }
        return GitHubActivityEntry(
            reason: .assigned, repo: repo, issue: issue,
            activityAt: issue.updatedAt ?? "",
            actor: Self.latest(assignedToMe, by: { $0.createdAt })?.actor?.login
        )
    }

    private static let changeEvents = GitHubClient.GitHubIssueEvent.changeEvents

    private static func latest<T>(_ items: [T], by timestamp: (T) -> String) -> T? {
        items.max { a, b in
            (parseActivityDate(timestamp(a)) ?? .distantPast) < (parseActivityDate(timestamp(b)) ?? .distantPast)
        }
    }

    private static func sorted(_ entries: [GitHubActivityEntry]) -> [GitHubActivityEntry] {
        entries.sorted { a, b in
            (parseActivityDate(a.activityAt) ?? .distantPast) > (parseActivityDate(b.activityAt) ?? .distantPast)
        }
    }
}
