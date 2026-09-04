import Foundation
import Combine

/// Live model for one Jira Space (project board). Issues are fetched from the
/// API on load/refresh; not stored locally.
/// Persisted board snapshot for cache-then-network loading.
struct CachedJiraBoard: Codable {
    let statuses: [JiraStatus]
    let issues: [JiraIssue]
    /// The logged-in user's account ID, cached so the "My tickets only"
    /// filter can engage on the very first frame instead of flashing all
    /// issues until the `myself()` call returns.
    let myAccountID: String?
    let fetchedAt: Date
}

final class JiraBoardModel: ObservableObject, KeyboardNavigable {
    let space: JiraSpace
    let account: JiraAccount
    let client: JiraClient
    let cache: BoardCaching?

    @Published private(set) var statuses: [JiraStatus] = []
    @Published private(set) var issues: [JiraIssue] = []
    @Published var lastError: String?
    @Published private(set) var isLoading = false
    @Published var lastUpdated: Date?
    /// True while the visible content comes from the cache and the
    /// network refresh is still in flight.
    @Published private(set) var showingCached = false

    private var cacheKey: String { "jira-board-\(space.id)" }

    init(account: JiraAccount, space: JiraSpace, token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.space = space
        self.cache = cache
        self.client = JiraClient(credentials: .init(
            baseURL: account.baseURL,
            email: account.email,
            apiToken: token
        ))
    }

    var jql: String {
        if let custom = space.jql?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return custom
        }
        return "project = \(space.projectKey) ORDER BY updated DESC"
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
        Diag.log.info("load start project=\(self.space.projectKey, privacy: .public) force=\(force, privacy: .public)")
        // "My tickets only" needs the logged-in user's account id — fetch it
        // in the background so it never delays the cache publish or network
        // fetch. Until it arrives the filter simply shows everything.
        if mineOnly, myAccountID == nil {
            Task { @MainActor in
                if let me = try? await self.client.myself() {
                    self.myAccountID = me.accountID
                }
            }
        }
        // Cache-first: publish the last successful fetch immediately so the
        // board is usable while the network request is in flight.
        var cacheIsFresh = false
        if issues.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode(CachedJiraBoard.self, from: entry.data) {
            statuses = snapshot.statuses
            issues = snapshot.issues
            if let cached = snapshot.myAccountID {
                // Apply the "My tickets only" filter immediately — otherwise
                // the board would flash every issue until the background
                // `myself()` call returns.
                self.myAccountID = cached
            }
            lastUpdated = entry.fetchedAt
            showingCached = true
            cacheIsFresh = Date().timeIntervalSince(entry.fetchedAt) < 60
            Diag.log.info("load published cached snapshot issues=\(snapshot.issues.count, privacy: .public) fresh=\(cacheIsFresh, privacy: .public)")
        }
        // Cache is under a minute old: skip the network round-trip.
        if !force, cacheIsFresh {
            Diag.log.info("load skipped: cache < 60s old")
            isLoading = false
            return
        }
        isLoading = true
        lastError = nil
        do {
            async let statusesTask = client.projectStatuses(projectKey: space.projectKey)
            async let issuesTask = client.search(jql: jql)
            let (s, i) = try await (statusesTask, issuesTask)
            Diag.log.info("load decoded statuses=\(s.count) issues=\(i.issues?.count ?? -1)")
            statuses = s
            issues = i.issues?.map { issue in
                JiraIssue(
                    key: issue.key,
                    fields: .init(
                        summary: issue.fields.summary ?? "",
                        description: issue.fields.description,
                        status: .init(
                            name: issue.fields.status.name,
                            statusCategory: .init(key: issue.fields.status.statusCategory.key)
                        ),
                        issuetype: .init(name: issue.fields.issuetype.name, iconURL: issue.fields.issuetype.iconURL),
                        assignee: issue.fields.assignee.map {
                            .init(displayName: $0.displayName, accountID: $0.accountID)
                        },
                        priority: issue.fields.priority.map { .init(name: $0.name) },
                        updated: issue.fields.updated
                    )
                )
            } ?? []
            lastUpdated = Date()
            showingCached = false
            if let cache,
               let payload = try? JSONEncoder().encode(
                   CachedJiraBoard(statuses: statuses, issues: issues, myAccountID: myAccountID, fetchedAt: lastUpdated!)
               ) {
                cache.storeCachedData(payload, for: cacheKey)
            }
            Diag.log.info("load assigned, triggering board render")
        } catch {
            lastError = "\(error.localizedDescription)"
            Diag.log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
    }

    // MARK: Board structure

    /// Delete an issue on the server; removes it from the board only on
    /// success (the confirmation sheet already guards accidents).
    @MainActor
    func deleteIssue(issueKey: String) async -> Bool {
        do {
            try await client.deleteIssue(key: issueKey)
            issues.removeAll { $0.key == issueKey }
            return true
        } catch {
            Diag.log.error("jira deleteIssue failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't delete \(issueKey): \(error.localizedDescription)"
            return false
        }
    }

    /// Active board filter (synced from AppModel.filterText by the view).
    @Published var filterText: String = ""
    /// "My tickets only": pre-selected; filters each lane to issues whose
    /// assignee is the logged-in user. Client-side, so toggling is instant.
    @Published var mineOnly = true
    /// Account id of the logged-in user (fetched once on first load; nil
    /// until then, which the filter treats as "don't filter yet").
    @Published private(set) var myAccountID: String?

    func issues(inStatus statusName: String) -> [JiraIssue] {
        let base = issues.filter { $0.fields.status.name == statusName }
        let scoped = mineOnly && myAccountID != nil
            ? base.filter { $0.fields.assignee?.accountID == myAccountID }
            : base
        let f = filterText
        guard !f.isEmpty else { return scoped }
        return scoped.filter {
            $0.key.localizedCaseInsensitiveContains(f) ||
            $0.fields.summary.localizedCaseInsensitiveContains(f)
        }
    }

    /// Move an issue to a status lane via a transition. Optimistic: the
    /// card changes lane instantly and the server call follows; on failure
    /// the move is reverted (server response is the truth, like comments).
    /// All @Published mutations happen on the main actor.
    @MainActor
    func transition(issueKey: String, toStatus statusName: String) async -> Bool {
        guard let idx = issues.firstIndex(where: { $0.key == issueKey }) else { return false }
        let previous = issues[idx].fields.status
        let match = statuses.first { $0.name == statusName }
        issues[idx].fields.status.name = statusName
        issues[idx].fields.status.statusCategory.key = match?.categoryKey ?? "indeterminate"
        do {
            try await client.transitionTo(key: issueKey, statusName: statusName)
            return true
        } catch let JiraError.ambiguousTransition(names) {
            issues[idx].fields.status = previous
            lastError = "Ambiguous transition: \(names.joined(separator: " / ")) — use the detail view to pick one."
            return false
        } catch {
            issues[idx].fields.status = previous
            lastError = error.localizedDescription
            return false
        }
    }

    /// Apply a successful server edit to the board copy in place — the
    /// sheet has already PUT the changes; this keeps the card in sync
    /// without a reload. Status/lanes untouched.
    @MainActor
    func applyEdit(issueKey: String, summary: String, description: ADFDocument, assignee: JiraIssue.Fields.Assignee?, priority: JiraIssue.Fields.Priority?) {
        guard let idx = issues.firstIndex(where: { $0.key == issueKey }) else { return }
        issues[idx].fields.summary = summary
        issues[idx].fields.description = description.plainText.isEmpty ? nil : description
        issues[idx].fields.assignee = assignee
        issues[idx].fields.priority = priority
    }

    /// All transitions for an issue (used in detail view picker).
    func transitions(for issueKey: String) async -> [JiraTransition] {
        (try? await client.transitions(key: issueKey)) ?? []
    }

    @MainActor
    /// `accepted` mirrors the HTTP status: true means the server stored the
    /// comment. `created` is the server-rendered replacement for the local
    /// placeholder, or nil if the response didn't decode (keep placeholder).
    func addComment(issueKey: String, _ body: ADFDocument) async -> (accepted: Bool, created: JiraCommentPage.Comment?) {
        do {
            let created = try await client.addComment(key: issueKey, body: body)
            return (true, created)
        } catch {
            Diag.log.error("jira addComment failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return (false, nil)
        }
    }

    /// Insert a freshly created issue at the top of the board (newest
    /// updated first) and make sure its status lane exists.
    func insertCreated(_ issue: JiraIssue) {
        issues.insert(issue, at: 0)
        if !statuses.contains(where: { $0.name == issue.fields.status.name }) {
            statuses.append(JiraStatus(name: issue.fields.status.name, categoryKey: issue.fields.status.statusCategory.key))
        }
    }

    func editComment(issueKey: String, id: String, body: ADFDocument) async -> Bool {
        do {
            try await client.updateComment(key: issueKey, id: id, body: body)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func deleteComment(issueKey: String, id: String) async -> Bool {
        do {
            try await client.deleteComment(key: issueKey, id: id)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @MainActor
    func addAttachment(issueKey: String, fileURL: URL) async -> Bool {
        do {
            _ = try await client.addAttachment(key: issueKey, fileURL: fileURL)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: KeyboardNavigable

    var navLaneCount: Int { statuses.count }

    func navItemCount(lane: Int) -> Int {
        guard lane < statuses.count else { return 0 }
        return issues(inStatus: statuses[lane].name).count
    }

    func navMove(lane: Int, item: Int) -> Bool {
        // Selection is visual; nothing to persist here.
        true
    }

    func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool {
        // H/L keys: move issue to adjacent status lane.
        guard toLaneDelta != 0 else { return false }
        let target = lane + toLaneDelta
        guard target >= 0, target < statuses.count,
              lane < statuses.count,
              let issue = issues(inStatus: statuses[lane].name).indices.contains(item)
                  ? issues(inStatus: statuses[lane].name)[safe: item] : nil else { return false }
        let statusName = statuses[target].name
        Task { @MainActor in _ = await self.transition(issueKey: issue.key, toStatus: statusName) }
        return true
    }

    func navOpenDetail(lane: Int, item: Int) {}
    func navBeginRename(lane: Int, item: Int) {}
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Mentions model

/// Shows issues mentioning the signed-in user for one account.
final class MentionsModel: ObservableObject {
    let account: JiraAccount
    let client: JiraClient
    let space: JiraSpace
    let token: String
    let cache: BoardCaching?

    private var cacheKey: String { "jira-mentions-\(space.id)" }

    @Published private(set) var mentioned: [JiraIssue] = []
    @Published var lastError: String?
    @Published private(set) var isLoading = false
    @Published var lastUpdated: Date?
    /// True while the visible list comes from the cache and the network
    /// refresh is still in flight (same semantics as the boards).
    @Published private(set) var showingCached = false

    init(account: JiraAccount, space: JiraSpace, token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.space = space
        self.token = token
        self.cache = cache
        self.client = JiraClient(credentials: .init(
            baseURL: account.baseURL,
            email: account.email,
            apiToken: token
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
        if mentioned.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode([JiraIssue].self, from: entry.data) {
            mentioned = snapshot
            lastUpdated = entry.fetchedAt
            showingCached = true
            cacheIsFresh = Date().timeIntervalSince(entry.fetchedAt) < 60
        }
        // Cache is under a minute old: skip the network round-trip.
        if !force, cacheIsFresh {
            Diag.log.info("mentions load skipped: cache < 60s old")
            isLoading = false
            return
        }
        isLoading = true
        lastError = nil
        do {
            let me = try await client.myself()
            // Escape quotes/backslashes for the phrase search so display
            // names with specials don't break the JQL.
            let name = me.displayName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let jql = "project = \(space.projectKey) AND text ~ \"@\(name)\" ORDER BY updated DESC"
            let result = try await client.search(jql: jql, fields: ["summary", "status", "issuetype", "updated"])
            let fresh = result.issues?.map { issue in
                JiraIssue(
                    key: issue.key,
                    fields: .init(
                        summary: issue.fields.summary ?? "",
                        description: nil,
                        status: .init(
                            name: issue.fields.status.name,
                            statusCategory: .init(key: issue.fields.status.statusCategory.key)
                        ),
                        issuetype: .init(name: issue.fields.issuetype.name, iconURL: issue.fields.issuetype.iconURL),
                        assignee: nil,
                        priority: nil,
                        updated: issue.fields.updated
                    )
                )
            } ?? []
            mentioned = fresh
            lastUpdated = Date()
            showingCached = false
            if let cache, let data = try? JSONEncoder().encode(fresh) {
                cache.storeCachedData(data, for: cacheKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}