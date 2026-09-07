import Testing
import Foundation
@testable import Todo

// MARK: - GraphQL activity search (one request for all repos)
//
// Pure query construction + response parsing, no network.

@Test func graphqlActivityQueryAliasesEveryRepoAndReason() {
    let repos = [
        GitHubRepo(id: 1, accountID: 1, name: "r1", owner: "some-org", repo: "r1"),
        GitHubRepo(id: 2, accountID: 1, name: "r2", owner: "some-org", repo: "r2"),
    ]
    let (query, aliases) = GitHubClient.makeActivityQuery(repos: repos, login: "kalle")

    // 2 repos × 4 searches, in stable per-repo order — assigned comes
    // before owned so the analysis plan's dedupe keeps the "assigned"
    // fallback for issues that are both.
    #expect(aliases.count == 8)
    #expect(aliases.map(\.alias) == ["m0", "a0", "r0", "o0", "m1", "a1", "r1", "o1"])
    #expect(aliases[0].reason == .mention)
    #expect(aliases[1].reason == .assigned)
    #expect(aliases[2].reason == .reviewRequested)
    #expect(aliases[3].reason == .owned)
    #expect(aliases[4].repo.name == "r2")

    // Every search is repo-scoped and aliased into the single document;
    // updated-desc keeps the 50-per-search cap honest for a feed.
    #expect(query.contains(#"m0: search(query: "repo:some-org/r1 is:issue mentions:kalle sort:updated-desc", type: ISSUE, first: 50)"#))
    #expect(query.contains("repo:some-org/r1 assignee:kalle sort:updated-desc"))
    #expect(query.contains("repo:some-org/r2 is:pr is:open review-requested:kalle sort:updated-desc"))
    #expect(query.contains("repo:some-org/r2 author:kalle sort:updated-desc"))
    #expect(query.hasPrefix("query {"))
    // PRs decode from the same node fields — but stateReason is
    // Issue-only: requesting it on PullRequest fails the WHOLE query
    // with data null. Exactly one stateReason per search (the Issue
    // fragment), none in the PullRequest fragment.
    #expect(query.contains("... on PullRequest { number title body state url updatedAt"))
    #expect(query.contains(" stateReason } ... on PullRequest"))
    #expect(query.components(separatedBy: "stateReason").count == 9) // 8 Issue fragments + tail
    // Quote/backslash sanitizing for the interpolated login.
    let (unsafe, _) = GitHubClient.makeActivityQuery(repos: repos, login: #"we"ird\login"#)
    #expect(!unsafe.contains(#"we"ird"#))

    // No repos → empty query, empty aliases.
    let (empty, emptyAliases) = GitHubClient.makeActivityQuery(repos: [], login: "x")
    #expect(empty == "query {  }")
    #expect(emptyAliases.isEmpty)
}

@Test func graphqlActivityResponseDecodesAndMaps() throws {
    let fixture = """
    {
      "data": {
        "m0": {
          "nodes": [
            {
              "__typename": "Issue",
              "number": 5,
              "title": "Fix the thing",
              "body": null,
              "state": "OPEN",
              "stateReason": null,
              "url": "https://example.com/5",
              "updatedAt": "2026-09-04T08:00:00Z",
              "labels": { "nodes": [ { "name": "bug", "color": "ff0000" } ] },
              "assignees": { "nodes": [ { "login": "kalle", "name": "Kalle" } ] },
              "repository": { "nameWithOwner": "some-org/r1" }
            }
          ]
        },
        "a0": {
          "nodes": [
            {
              "__typename": "PullRequest",
              "number": 7,
              "title": "Refactor",
              "body": "b",
              "state": "MERGED",
              "stateReason": "COMPLETED",
              "url": "https://example.com/7",
              "updatedAt": "2026-09-03T08:00:00Z",
              "labels": { "nodes": [] },
              "assignees": { "nodes": [] },
              "repository": { "nameWithOwner": "some-org/r1" }
            }
          ]
        },
        "r0": { "nodes": [] }
      }
    }
    """
    let envelope = try JSONDecoder().decode(
        GitHubClient.GraphQLActivityEnvelope.self, from: Data(fixture.utf8)
    )
    let repo = GitHubRepo(id: 1, accountID: 1, name: "r1", owner: "some-org", repo: "r1")
    let aliases: [(alias: String, repo: GitHubRepo, reason: ActivityReason)] = [
        ("m0", repo, .mention),
        ("a0", repo, .assigned),
        ("r0", repo, .reviewRequested),
    ]
    let hits = GitHubClient.parseActivityResponse(envelope, aliases: aliases)
    #expect(hits.count == 2)

    // GraphQL enums are uppercased — mapped to REST-shaped lowercase.
    let issue = hits[0]
    #expect(issue.reason == .mention)
    #expect(issue.issue.number == 5)
    #expect(issue.issue.state == "open")
    #expect(issue.issue.stateReason == nil)
    #expect(issue.issue.pullRequest == nil)
    #expect(issue.issue.labels == [GitHubLabel(name: "bug", color: "ff0000")])
    #expect(issue.issue.assignees?.first?.login == "kalle")

    // Merged PR keeps its marker; state collapses like the REST payload.
    let pr = hits[1]
    #expect(pr.reason == .assigned)
    #expect(pr.issue.pullRequest != nil)
    #expect(pr.issue.state == "merged")
    #expect(pr.issue.stateReason == "completed")

    // Empty page contributes nothing; missing alias is tolerated.
    let partial = GitHubClient.parseActivityResponse(envelope, aliases: [("r0", repo, .reviewRequested)])
    #expect(partial.isEmpty)
}

// MARK: - Analysis plan (which hits get per-issue comment/event analysis)

private func ghIssue(_ number: Int) -> GitHubIssue {
    GitHubIssue(number: number, title: "t", body: nil, state: "open",
                stateReason: nil, htmlURL: nil, updatedAt: "2026-09-04T08:00:00Z",
                labels: [], assignees: nil, pullRequest: nil)
}

@Test func analysisPlanDedupesAndKeepsAssignedFallback() {
    let repo = GitHubRepo(id: 1, accountID: 1, name: "r", owner: "org", repo: "r")
    let hits = [
        GitHubClient.GitHubActivityHit(repo: repo, reason: .mention, issue: ghIssue(1)),
        GitHubClient.GitHubActivityHit(repo: repo, reason: .assigned, issue: ghIssue(2)),
        GitHubClient.GitHubActivityHit(repo: repo, reason: .owned, issue: ghIssue(2)),   // both
        GitHubClient.GitHubActivityHit(repo: repo, reason: .owned, issue: ghIssue(3)),   // owned only
        GitHubClient.GitHubActivityHit(repo: repo, reason: .reviewRequested, issue: ghIssue(4)), // skipped
    ]
    let plan = GitHubActivityModel.analysisPlan(hits)
    // Mentions and review requests need no analysis; #2 dedupes to the
    // assigned hit (assigned precedes owned in the query) so it keeps
    // the "assigned" fallback.
    #expect(plan.map(\.hit.issue.number) == [2, 3])
    #expect(plan[0].fallbackAssigned == true)
    #expect(plan[1].fallbackAssigned == false)
}
