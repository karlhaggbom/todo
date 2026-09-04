import Testing
import Foundation
@testable import Todo

// MARK: - Activity feed core logic
//
// The feed's merge/ordering/read-key behavior is pure — everything here
// runs without network access.

@Test func parseActivityDateHandlesBothAPIShapes() {
    // Jira: fractional seconds, colon-less UTC offset.
    let jira = parseActivityDate("2026-09-04T08:00:00.123+0000")
    #expect(jira != nil)

    // GitHub: trailing Z.
    let github = parseActivityDate("2026-09-04T08:00:00Z")
    #expect(github != nil)

    // Same instant, different encodings: equal.
    #expect(jira.map { floor($0.timeIntervalSince1970) } == github.map { floor($0.timeIntervalSince1970) })

    // Junk is nil, never a crash.
    #expect(parseActivityDate("") == nil)
    #expect(parseActivityDate("nonsense") == nil)
}

@Test func activityReadKeysAnchorToTheActivityNotTheIssue() {
    let issue = JiraIssue(key: "TAP-9", fields: .init(
        summary: "s", description: nil,
        status: .init(name: "To Do", statusCategory: .init(key: "new")),
        issuetype: .init(name: "Task", iconURL: nil),
        assignee: nil, priority: nil,
        updated: "2026-09-01T08:00:00.000+0000"
    ))
    // Two entries for the same issue at different activity times: distinct
    // read keys, so a new comment on a read issue surfaces as unread.
    let read = JiraActivityEntry(reason: .mention, issue: issue, activityAt: "2026-09-01T08:00:00.000+0000", actor: nil)
    let updated = JiraActivityEntry(reason: .comment, issue: issue, activityAt: "2026-09-05T10:00:00.000+0000", actor: "Jane")
    #expect(read.readKey != updated.readKey)
    #expect(read.readKey == "TAP-9@2026-09-01T08:00:00.000+0000")

    // Same for GitHub, anchored on the stable owner/repo#number base.
    let repo = GitHubRepo(id: 1, accountID: 1, name: "r", owner: "org", repo: "r")
    let ghRead = GitHubActivityEntry(
        reason: .assigned, repo: repo,
        issue: ghIssue(number: 5, updatedAt: "2026-09-01T08:00:00Z"),
        activityAt: "2026-09-01T08:00:00Z", actor: nil
    )
    let ghUpdated = GitHubActivityEntry(
        reason: .change, repo: repo,
        issue: ghIssue(number: 5, updatedAt: "2026-09-04T08:00:00Z"),
        activityAt: "2026-09-04T08:00:00Z", actor: nil
    )
    #expect(ghRead.readKey == "org/r#5@2026-09-01T08:00:00Z")
    #expect(ghRead.readKey != ghUpdated.readKey)
}

@Test func newestKeepsTheMostRecentActivity() {
    let base = JiraIssue(key: "TAP-1", fields: .init(
        summary: "s", description: nil,
        status: .init(name: "To Do", statusCategory: .init(key: "new")),
        issuetype: .init(name: "Task", iconURL: nil),
        assignee: nil, priority: nil,
        updated: "2026-09-05T08:00:00.000+0000"
    ))
    // A fresh comment beats an older mention.
    let oldMention = JiraActivityEntry(reason: .mention, issue: base, activityAt: "2026-09-01T08:00:00.000+0000", actor: nil)
    let newComment = JiraActivityEntry(reason: .comment, issue: base, activityAt: "2026-09-05T10:00:00.000+0000", actor: "Jane")
    #expect(JiraActivityEntry.newest(oldMention, newComment).reason == .comment)
    #expect(JiraActivityEntry.newest(newComment, oldMention).reason == .comment)
    // Ties keep the first (earlier-seeded) entry.
    let tie = JiraActivityEntry(reason: .mention, issue: base, activityAt: newComment.activityAt, actor: nil)
    #expect(JiraActivityEntry.newest(tie, newComment).reason == .mention)

    // GitHub mirror.
    let repo = GitHubRepo(id: 1, accountID: 1, name: "r", owner: "org", repo: "r")
    let gOld = GitHubActivityEntry(reason: .mention, repo: repo, issue: ghIssue(number: 1, updatedAt: "2026-09-01T08:00:00Z"), activityAt: "2026-09-01T08:00:00Z", actor: nil)
    let gNew = GitHubActivityEntry(reason: .change, repo: repo, issue: ghIssue(number: 1, updatedAt: "2026-09-05T08:00:00Z"), activityAt: "2026-09-05T08:00:00Z", actor: "jane")
    #expect(GitHubActivityEntry.newest(gOld, gNew).reason == .change)
    #expect(GitHubActivityEntry.newest(gNew, gOld).reason == .change)
}

@Test func unparseableActivityTimestampsSortLast() {
    let base = JiraIssue(key: "TAP-2", fields: .init(
        summary: "s", description: nil,
        status: .init(name: "To Do", statusCategory: .init(key: "new")),
        issuetype: .init(name: "Task", iconURL: nil),
        assignee: nil, priority: nil,
        updated: "2026-09-05T08:00:00.000+0000"
    ))
    let broken = JiraActivityEntry(reason: .mention, issue: base, activityAt: "", actor: nil)
    let dated = JiraActivityEntry(reason: .assigned, issue: base, activityAt: "2026-01-01T00:00:00.000+0000", actor: nil)
    // Broken loses to anything decodable, in either order.
    #expect(JiraActivityEntry.newest(broken, dated).reason == .assigned)
    #expect(JiraActivityEntry.newest(dated, broken).reason == .assigned)
}

@Test func trayUnreadCountSubtractsReadSetAcrossAccounts() {
    let jira: [Int64: Set<String>] = [
        1: ["TAP-1@t1", "TAP-2@t2", "TAP-3@t3"],
        2: ["BUG-9@t9"],
    ]
    let github: [Int64: Set<String>] = [
        3: ["org/r#5@t5", "org/r#6@t6"],
        4: [],
    ]
    let read: Set<String> = ["TAP-1@t1", "org/r#5@t5"]
    // 2 unread on Jira (TAP-2, TAP-3) + 1 on Jira acct 2 + 1 on GitHub.
    #expect(TrayIconController.unreadCount(jira: jira, github: github, read: read) == 4)
    // Everything read → 0 (icon unbadges).
    let all = Set(jira.values.flatMap { $0 } + github.values.flatMap { $0 })
    #expect(TrayIconController.unreadCount(jira: jira, github: github, read: all) == 0)
    // No accounts at all → 0.
    #expect(TrayIconController.unreadCount(jira: [:], github: [:], read: []) == 0)
}

private func ghIssue(number: Int, updatedAt: String) -> GitHubIssue {
    GitHubIssue(
        number: number, title: "t", body: nil, state: "open",
        stateReason: nil, htmlURL: nil, updatedAt: updatedAt,
        labels: [], assignees: [], pullRequest: nil
    )
}