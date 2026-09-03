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
        Diag.log.info("github load start repo=\(self.repo.owner)/\(self.repo.repo, privacy: .public)")
        // Cache-first: publish the last successful fetch immediately so the
        // board is usable while the network request is in flight.
        if issues.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode(CachedGitHubBoard.self, from: entry.data) {
            issues = snapshot.issues
            lastUpdated = entry.fetchedAt
            showingCached = true
            Diag.log.info("github published cached snapshot issues=\(snapshot.issues.count, privacy: .public)")
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

    func refresh() async {
        await load()
    }

    // MARK: Board structure

    func issues(inLane laneID: String) -> [GitHubIssue] {
        let base = issues.filter { $0.laneID == laneID }
        let f = filterText
        guard !f.isEmpty else { return base }
        let int = Int(f)
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(f) ||
            (int != nil && $0.number == int)
        }
    }

    /// Transition an issue to another lane (open / completed / not planned)
    /// and optimistically update local state.
    @MainActor
    func transition(issueNumber: Int, toLane laneID: String) async -> Bool {
        do {
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
            let updated = try await client.patchIssue(
                owner: repo.owner, repo: repo.repo, number: issueNumber,
                state: state, stateReason: stateReason
            )
            if let idx = issues.firstIndex(where: { $0.number == issueNumber }) {
                issues[idx] = updated
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @MainActor
    func addComment(issueNumber: Int, body: String) async -> Bool {
        do {
            _ = try await client.addComment(
                owner: repo.owner, repo: repo.repo, number: issueNumber, body: body
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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
final class GitHubMentionsModel: ObservableObject {
    let account: GitHubAccount
    let client: GitHubClient
    let repos: [GitHubRepo]

    @Published private(set) var mentioned: [GitHubMentionedIssue] = []
    @Published var lastError: String?
    @Published private(set) var isLoading = false

    init(account: GitHubAccount, repos: [GitHubRepo], token: String) {
        self.account = account
        self.repos = repos
        self.client = GitHubClient(credentials: .init(
            baseURL: account.baseURL,
            token: token
        ))
    }

    @MainActor
    func load() async {
        isLoading = true
        lastError = nil
        do {
            var seen = Set<String>()
            var results: [GitHubMentionedIssue] = []
            for repo in repos {
                let hits = try await client.issuesMentioning(
                    owner: repo.owner, repo: repo.repo, login: account.login
                )
                for issue in hits {
                    let key = "\(repo.owner)/\(repo.repo)#\(issue.number)"
                    guard seen.insert(key).inserted else { continue }
                    results.append(GitHubMentionedIssue(repo: repo, issue: issue))
                }
            }
            mentioned = results
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

struct GitHubMentionedIssue: Identifiable, Hashable {
    let repo: GitHubRepo
    let issue: GitHubIssue
    var id: String { "\(repo.id)-\(issue.number)" }
}