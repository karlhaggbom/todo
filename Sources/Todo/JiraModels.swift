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
        mineOnly = AppPreferences.mineOnly(spaceID: space.id)
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
    /// "My tickets only": persisted per space; filters each lane to issues
    /// whose assignee is the logged-in user. Client-side, so toggling is
    /// instant. The didSet write-through persists the toggle (initial
    /// assignment in init doesn't trigger it, by Swift's rules).
    @Published var mineOnly = true {
        didSet { AppPreferences.setMineOnly(mineOnly, spaceID: space.id) }
    }
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
final class ActivityModel: ObservableObject {
    let account: JiraAccount
    let client: JiraClient
    let space: JiraSpace
    let token: String
    let cache: BoardCaching?

    private var cacheKey: String { "jira-activity-\(space.id)" }

    /// The activity feed, newest first. One entry per issue; each carries
    /// the single most recent reason it impacts the user: a mention, an
    /// assignment, someone else's comment, or someone else's change.
    @Published private(set) var activity: [JiraActivityEntry] = []
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
        if activity.isEmpty, let cache,
           let entry = cache.cachedData(for: cacheKey),
           let snapshot = try? JSONDecoder().decode([JiraActivityEntry].self, from: entry.data) {
            activity = Self.sorted(snapshot)
            lastUpdated = entry.fetchedAt
            showingCached = true
            cacheIsFresh = Date().timeIntervalSince(entry.fetchedAt) < 60
        }
        // Cache is under a minute old: skip the network round-trip.
        if !force, cacheIsFresh {
            Diag.log.info("activity load skipped: cache < 60s old")
            isLoading = false
            return
        }
        isLoading = true
        lastError = nil
        do {
            let me = try await client.myself()
            // Full refreshes run on force-refresh, when the feed is empty
            // (nothing to merge into), when the last full is over an hour
            // old (deltas can't detect removals — unassigned from me,
            // mention edited away), and when the gap since the last
            // successful fetch exceeds a day. Everything else is a DELTA
            // that scales its window to everything missed since that last
            // successful fetch — which persists across app restarts and
            // machine shutdowns, so time with Todo closed still gets
            // picked up. The relative JQL form is evaluated against
            // Jira's clock, so there is no timezone or clock-skew risk.
            let lastFull = AppPreferences.activityLastFull(scope: cacheKey)
            let sinceFull = lastFull.map { Date().timeIntervalSince($0) }
            let sinceFetch = AppPreferences.activityLastFetch(scope: cacheKey)
                .map { Date().timeIntervalSince($0) }
            let deltaMinutes = Self.deltaMinutes(sinceFetch: sinceFetch)
            let needsFull = force
                || deltaMinutes == nil
                || sinceFull == nil
                || activity.isEmpty
                || sinceFull! > 3600
            let deltaFilter = needsFull
                ? "" : " AND updated >= \"-\(deltaMinutes!)m\""
            // Two searches in parallel: mentions, and everything assigned
            // to me (ownership proxy for "changes/comments on my tickets").
            // Escape quotes/backslashes for the phrase search so display
            // names with specials don't break the JQL.
            let name = me.displayName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            async let mentionsTask = client.search(
                jql: "project = \(space.projectKey) AND text ~ \"@\(name)\"" + deltaFilter + " ORDER BY updated DESC",
                fields: ["summary", "status", "issuetype", "updated"]
            )
            async let assignedTask = client.search(
                jql: "project = \(space.projectKey) AND assignee = currentUser()" + deltaFilter + " ORDER BY updated DESC",
                fields: ["summary", "status", "issuetype", "assignee", "priority", "updated"]
            )
            let (mentions, assigned) = try await (mentionsTask, assignedTask)

            var updates: [JiraActivityEntry] = []
            for issue in mentions.issues ?? [] {
                let mapped = Self.map(issue, withAssignee: false)
                updates.append(JiraActivityEntry(
                    reason: .mention, issue: mapped,
                    activityAt: mapped.fields.updated ?? "", actor: nil
                ))
            }
            // Analyze assigned issues in parallel — a bounded pool (6 at a
            // time) stays polite to the API while cutting the tick's
            // wall-clock time several-fold versus one-at-a-time fetches.
            let mappedAssigned = (assigned.issues ?? []).map { Self.map($0, withAssignee: true) }
            let analyzed: [JiraActivityEntry] = await withTaskGroup(of: JiraActivityEntry?.self) { group in
                var nextIndex = 0
                let limit = 6
                func startNext() {
                    guard nextIndex < mappedAssigned.count else { return }
                    let issue = mappedAssigned[nextIndex]
                    nextIndex += 1
                    group.addTask { await self.assignedEntry(issue, me: me) }
                }
                for _ in 0..<min(limit, mappedAssigned.count) { startNext() }
                var collected: [JiraActivityEntry] = []
                while let result = await group.next() {
                    if let result { collected.append(result) }
                    startNext()
                }
                return collected
            }
            updates.append(contentsOf: analyzed)
            // Delta merge: keep every already-known entry; only issues the
            // search returned get recomputed. (A full refresh starts from
            // an empty base, which gives the old "replace" behavior.)
            let fresh = Self.mergedActivity(existing: needsFull ? [] : activity, updates: updates)
            activity = fresh
            lastUpdated = Date()
            showingCached = false
            if let cache, let data = try? JSONEncoder().encode(fresh) {
                cache.storeCachedData(data, for: cacheKey)
            }
            // Both full and delta loads, on success, advance the fetch
            // marker; failures must leave it alone so the next tick
            // re-covers the gap.
            AppPreferences.setActivityLastFetch(Date(), scope: cacheKey)
            if needsFull { AppPreferences.setActivityLastFull(Date(), scope: cacheKey) }
            Diag.log.info("activity loaded entries=\(fresh.count, privacy: .public) delta=\(!needsFull, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// The delta window in minutes: everything missed since the last
    /// successful fetch, plus a small overlap, at least the 15-minute
    /// floor. nil = do a full refresh instead (never fetched, or the
    /// gap is over a day). Pure — unit-tested.
    static func deltaMinutes(sinceFetch: TimeInterval?) -> Int? {
        guard let sinceFetch, sinceFetch <= 24 * 3600 else { return nil }
        return max(15, Int(sinceFetch / 60) + 5)
    }

    /// Merge freshly-computed entries into the known set: one entry per
    /// issue, newest reason wins, and entries the delta didn't return
    /// stay put (they were untouched). Pure — unit-tested.
    static func mergedActivity(
        existing: [JiraActivityEntry], updates: [JiraActivityEntry]
    ) -> [JiraActivityEntry] {
        var byKey: [String: JiraActivityEntry] = [:]
        for entry in existing { byKey[entry.id] = byKey[entry.id].map { JiraActivityEntry.newest($0, entry) } ?? entry }
        for entry in updates {
            byKey[entry.id] = byKey[entry.id].map { JiraActivityEntry.newest($0, entry) } ?? entry
        }
        return sorted(Array(byKey.values))
    }

    /// Analyze one issue assigned to me. Returns the most recent
    /// "someone else" activity: their comment, their change, or — with no
    /// other activity — the assignment itself. Returns nil when the only
    /// activity is my own (e.g. I assigned the issue to myself): own updates
    /// must never create feed entries.
    private func assignedEntry(_ issue: JiraIssue, me: JiraUser) async -> JiraActivityEntry? {
        // Issues untouched for a month can't hold recent activity — skip
        // their two per-issue API calls entirely (the entry stays, as the
        // plain assignment).
        if let updated = parseActivityDate(issue.fields.updated ?? ""),
           Date().timeIntervalSince(updated) > 30 * 24 * 3600 {
            return JiraActivityEntry(
                reason: .assigned, issue: issue,
                activityAt: issue.fields.updated ?? "", actor: nil
            )
        }
        // Comments and changelog don't depend on each other — fetch both
        // in parallel.
        async let commentsTask = client.comments(key: issue.key)
        async let changelogTask = client.changelog(key: issue.key)
        let comments = (try? await commentsTask)?.comments ?? []
        let changelog = (try? await changelogTask) ?? []
        let myID = me.accountID

        // Comments by someone else (nil accountId = synthesized/unknown →
        // not attributable, doesn't count as activity).
        let otherComments = comments.filter { c in
            guard let id = c.author?.accountId else { return false }
            return id != myID
        }
        if let latest = Self.latest(otherComments, by: { $0.created }) {
            return JiraActivityEntry(
                reason: .comment, issue: issue,
                activityAt: latest.created, actor: latest.author?.displayName
            )
        }
        // Field changes by someone else (status, priority, sprint, ...).
        let otherChanges = changelog.filter { e in
            guard let id = e.author?.accountId else { return false }
            return id != myID
        }
        if let latest = Self.latest(otherChanges, by: { $0.created }) {
            return JiraActivityEntry(
                reason: .change, issue: issue,
                activityAt: latest.created, actor: latest.author?.displayName
            )
        }
        // Nothing by anyone else: the assignment itself is the activity —
        // unless the last assignee-change-to-me was authored by me.
        let assignToMe = changelog.filter { e in
            e.items?.contains {
                $0.field == "assignee" && ($0.to == myID || $0.toString == me.displayName)
            } == true
        }
        if let last = Self.latest(assignToMe, by: { $0.created }),
           last.author?.accountId == myID {
            return nil // self-assigned: my own action, not activity
        }
        return JiraActivityEntry(
            reason: .assigned, issue: issue,
            activityAt: issue.fields.updated ?? "",
            actor: Self.latest(assignToMe, by: { $0.created })?.author?.displayName
        )
    }

    /// Map a raw search result into the app's issue shape. The mentions
    /// search doesn't request assignee/priority, so those stay nil there.
    private static func map(_ issue: JiraClient.SearchResponse.ResultIssue, withAssignee: Bool) -> JiraIssue {
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
                assignee: withAssignee
                    ? issue.fields.assignee.map { .init(displayName: $0.displayName, accountID: $0.accountID) }
                    : nil,
                priority: withAssignee
                    ? issue.fields.priority.map { .init(name: $0.name) }
                    : nil,
                updated: issue.fields.updated
            )
        )
    }

    private static func latest<T>(_ items: [T], by timestamp: (T) -> String) -> T? {
        items.max { a, b in
            (parseActivityDate(timestamp(a)) ?? .distantPast) < (parseActivityDate(timestamp(b)) ?? .distantPast)
        }
    }

    private static func sorted(_ entries: [JiraActivityEntry]) -> [JiraActivityEntry] {
        entries.sorted { a, b in
            (parseActivityDate(a.activityAt) ?? .distantPast) > (parseActivityDate(b.activityAt) ?? .distantPast)
        }
    }
}