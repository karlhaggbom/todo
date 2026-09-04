import Foundation

// MARK: - GitHub REST client (PAT bearer auth)

struct GitHubCredentials {
    let baseURL: String   // https://api.github.com or https://host/api/v3 (GHE)
    let token: String     // personal access token
}

enum GitHubError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)
    case noToken
    case badRepo
    case graphql(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid GitHub URL"
        case .http(let code, let body): return "GitHub HTTP \(code): \(body.prefix(300))"
        case .decode(let m): return "GitHub decode error: \(m)"
        case .noToken: return "Missing GitHub token in Keychain"
        case .badRepo: return "Invalid repository"
        case .graphql(let message): return "GitHub GraphQL: \(message.prefix(300))"
        }
    }
}

final class GitHubClient {
    let credentials: GitHubCredentials
    private let session: URLSession

    init(credentials: GitHubCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: Plumbing

    private func base() throws -> String {
        var url = credentials.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        guard URL(string: url) != nil else { throw GitHubError.badURL }
        return url
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: try base() + path) else { throw GitHubError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"] ?? String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decode("\(error)")
        }
    }

    private func repoPath(owner: String, repo: String) throws -> String {
        let o = owner.trimmingCharacters(in: .whitespaces)
        let r = repo.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !r.isEmpty, !o.contains("/"), !r.contains("/") else { throw GitHubError.badRepo }
        return "/repos/\(o)/\(r)"
    }

    // MARK: Endpoints

    /// The authenticated user (GET /user).
    func myself() async throws -> GitHubUser {
        try await send(request("GET", "/user"), as: GitHubUser.self)
    }

    /// All issues (open + closed) in a repo. Pull requests are filtered out.
    func issues(owner: String, repo: String) async throws -> [GitHubIssue] {
        let path = try repoPath(owner: owner, repo: repo) + "/issues?state=all&per_page=100"
        let all: [GitHubIssue] = try await send(request("GET", path), as: [GitHubIssue].self)
        return all.filter { $0.pullRequest == nil }
    }

    func issue(owner: String, repo: String, number: Int) async throws -> GitHubIssue {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)"
        return try await send(request("GET", path), as: GitHubIssue.self)
    }

    func comments(owner: String, repo: String, number: Int) async throws -> [GitHubComment] {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)/comments?per_page=100"
        return try await send(request("GET", path), as: [GitHubComment].self)
    }

    /// Post a comment. Returns the server-rendered comment when the
    /// response decodes. A 2xx status means the post succeeded — a decode
    /// miss returns nil but must NOT be treated as a failed post.
    @discardableResult
    func addComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment? {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)/comments"
        let payload = try JSONEncoder().encode(["body": body])
        let req = try request("POST", path, body: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                ?? String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(code, message)
        }
        return try? JSONDecoder().decode(GitHubComment.self, from: data)
    }

    @discardableResult
    func updateComment(owner: String, repo: String, id: Int, body: String) async throws -> GitHubComment {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/comments/\(id)"
        let payload = try JSONEncoder().encode(["body": body])
        return try await send(request("PATCH", path, body: payload), as: GitHubComment.self)
    }

    func deleteComment(owner: String, repo: String, id: Int) async throws {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/comments/\(id)"
        let (_, response) = try await session.data(for: request("DELETE", path))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GitHubError.http(code, "comment delete failed")
        }
    }

    /// Create an issue. Assignees require users who can be assigned in the
    /// repo (collaborators); empty list leaves the issue unassigned.
    @discardableResult
    func createIssue(owner: String, repo: String, title: String, body: String?, assignees: [String]) async throws -> GitHubIssue {
        struct CreatePayload: Encodable {
            let title: String
            let body: String?
            let assignees: [String]?
        }
        let path = try repoPath(owner: owner, repo: repo) + "/issues"
        let payload = try JSONEncoder().encode(
            CreatePayload(title: title, body: body, assignees: assignees.isEmpty ? nil : assignees)
        )
        return try await send(request("POST", path, body: payload), as: GitHubIssue.self)
    }

    /// Transition an issue between lanes. `stateReason` is only meaningful
    /// when closing ("completed" / "not_planned").
    @discardableResult
    func patchIssue(owner: String, repo: String, number: Int, state: String, stateReason: String? = nil) async throws -> GitHubIssue {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)"
        var fields: [String: String] = ["state": state]
        if let stateReason { fields["state_reason"] = stateReason }
        let payload = try JSONEncoder().encode(fields)
        return try await send(request("PATCH", path, body: payload), as: GitHubIssue.self)
    }

    /// Edit an existing issue's title/body/assignees. PATCH replaces the
    /// assignee list with the given one; returns the server-rendered issue.
    func editIssue(owner: String, repo: String, number: Int, title: String, body: String?, assignees: [String]) async throws -> GitHubIssue {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)"
        struct Payload: Encodable { let title: String; let body: String?; let assignees: [String] }
        let data = try JSONEncoder().encode(Payload(title: title, body: body, assignees: assignees))
        return try await send(request("PATCH", path, body: data), as: GitHubIssue.self)
    }

    /// Users who can be mentioned in this repo (collaborators).
    func collaborators(owner: String, repo: String) async throws -> [GitHubUser] {
        let path = try repoPath(owner: owner, repo: repo) + "/collaborators?per_page=100"
        return try await send(request("GET", path), as: [GitHubUser].self)
    }

    /// Issues in a repo that mention the given login (search API).
    /// Issues (not PRs) mentioning the user.
    func issuesMentioning(owner: String, repo: String, login: String) async throws -> [GitHubIssue] {
        try await issueSearch("repo:\(owner)/\(repo)+is:issue+mentions:\(login)")
            .filter { $0.pullRequest == nil }
    }

    /// Issues AND pull requests assigned to the user.
    func issuesAssigned(owner: String, repo: String, login: String) async throws -> [GitHubIssue] {
        try await issueSearch("repo:\(owner)/\(repo)+assignee:\(login)")
    }

    /// Open PRs where the user's review is requested.
    func prsReviewRequested(owner: String, repo: String, login: String) async throws -> [GitHubIssue] {
        try await issueSearch("repo:\(owner)/\(repo)+is:pr+is:open+review-requested:\(login)")
    }

    /// Shared search/issues query (issues and PRs live in the same index).
    private func issueSearch(_ q: String) async throws -> [GitHubIssue] {
        let path = "/search/issues?q=\(q)&per_page=50&sort=updated"
        struct Result: Decodable { let items: [GitHubIssue] }
        let result: Result = try await send(request("GET", path), as: Result.self)
        return result.items
    }

    // MARK: API: GraphQL activity search (ONE request for all repos)
    //
    // The REST search API hard-caps at 30 requests/minute, and three
    // searches per repo blew through that. GraphQL allows every search to
    // be aliased into a single request, paid from the 5000-points/hour
    // GraphQL budget instead — ~6 points per aliased search.

    /// One issue/PR found by the activity search, with why it matched.
    struct GitHubActivityHit: Hashable {
        let repo: GitHubRepo
        let reason: ActivityReason
        let issue: GitHubIssue
    }

    /// Fields shared by Issue and PullRequest search nodes. PullRequest
    /// must NOT ask for stateReason (it doesn't have the field — asking
    /// for it fails the WHOLE query with data:null).
    private static let activityNodeFields =
        "number title body state url updatedAt "
        + "labels(first: 20) { nodes { name color } } "
        + "assignees(first: 10) { nodes { login name } } "
        + "repository { nameWithOwner }"

    /// Builds the aliased search query plus the alias→(repo, reason) map.
    /// Pure — unit-tested without network.
    static func makeActivityQuery(repos: [GitHubRepo], login: String)
        -> (query: String, aliases: [(alias: String, repo: GitHubRepo, reason: ActivityReason)])
    {
        // Logins can only contain [a-zA-Z0-9-], but stay safe inside the
        // interpolated query string regardless.
        let safe = login.replacingOccurrences(of: "\"", with: "")
                     .replacingOccurrences(of: "\\", with: "")
        var aliases: [(String, GitHubRepo, ActivityReason)] = []
        var fields: [String] = []
        for (i, repo) in repos.enumerated() {
            let full = "\(repo.owner)/\(repo.repo)"
            let specs: [(String, String, ActivityReason)] = [
                ("m\(i)", "repo:\(full) is:issue mentions:\(safe)", .mention),
                ("a\(i)", "repo:\(full) assignee:\(safe)", .assigned),
                ("r\(i)", "repo:\(full) is:pr is:open review-requested:\(safe)", .reviewRequested),
            ]
            for spec in specs {
                aliases.append((spec.0, repo, spec.2))
                let nodes = "__typename "
                    // Only Issue carries stateReason (NOT_PLANNED etc.).
                    + "... on Issue { \(activityNodeFields) stateReason } "
                    + "... on PullRequest { \(activityNodeFields) }"
                fields.append(
                    "\(spec.0): search(query: \"\(spec.1)\", type: ISSUE, first: 50) { nodes { \(nodes) } }"
                )
            }
        }
        return ("query { \(fields.joined(separator: " ")) }", aliases)
    }

    private func graphqlEndpoint() throws -> URL {
        var url = try base()
        // GHE serves GraphQL from the site root, not the REST prefix.
        for suffix in ["/api/v3", "/api"] where url.hasSuffix(suffix) {
            url.removeLast(suffix.count)
        }
        guard let endpoint = URL(string: url + "/graphql") else { throw GitHubError.badURL }
        return endpoint
    }

    /// All activity searches for every repo in a single HTTP request.
    func activitySearch(repos: [GitHubRepo], login: String) async throws -> [GitHubActivityHit] {
        guard !repos.isEmpty else { return [] }
        let (query, aliases) = Self.makeActivityQuery(repos: repos, login: login)
        var req = URLRequest(url: try graphqlEndpoint())
        req.httpMethod = "POST"
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let envelope = try await send(req, as: GraphQLActivityEnvelope.self)
        // GraphQL reports failures as HTTP 200 + errors with data null —
        // surface that instead of silently seeing "no activity".
        guard envelope.data != nil else {
            let detail = envelope.errors?.compactMap(\.message).joined(separator: "; ") ?? "unknown GraphQL error"
            throw GitHubError.graphql(detail)
        }
        return Self.parseActivityResponse(envelope, aliases: aliases)
    }

    // MARK: GraphQL response decoding

    struct GraphQLConnection<T: Decodable>: Decodable { let nodes: [T]? }

    struct GraphQLActivityNode: Decodable {
        let __typename: String
        let number: Int
        let title: String
        let body: String?
        let state: String
        let stateReason: String?
        let url: String?
        let updatedAt: String
        let labels: GraphQLConnection<GitHubLabel>?
        let assignees: GraphQLConnection<GitHubUser>?
        let repository: Name?

        struct Name: Decodable { let nameWithOwner: String? }

        enum CodingKeys: String, CodingKey {
            case __typename, number, title, body, state, stateReason
            case url, updatedAt, labels, assignees, repository
        }

        /// Map into the app's REST-shaped issue (lowercase state enums;
        /// PR-ness via the marker, like the REST payload would).
        var issue: GitHubIssue {
            GitHubIssue(
                number: number,
                title: title,
                body: body,
                state: state.lowercased(),
                stateReason: stateReason?.lowercased(),
                htmlURL: url,
                updatedAt: updatedAt,
                labels: labels?.nodes ?? [],
                assignees: assignees?.nodes ?? [],
                pullRequest: __typename == "PullRequest" ? GitHubPullRequestMarker() : nil
            )
        }
    }

    struct GraphQLActivityEnvelope: Decodable {
        let data: GraphQLData?
        let errors: [GraphQLError]?

        struct GraphQLError: Decodable { let message: String? }
        struct GraphQLData: Decodable {
            let pages: [String: [GraphQLActivityNode]]
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: ArbitraryCodingKey.self)
                var dict: [String: [GraphQLActivityNode]] = [:]
                for key in container.allKeys {
                    struct Page: Decodable { let nodes: [GraphQLActivityNode]? }
                    let page = try container.decode(Page.self, forKey: key)
                    dict[key.stringValue] = page.nodes ?? []
                }
                pages = dict
            }
        }
        enum CodingKeys: String, CodingKey { case data, errors }
    }

    struct ArbitraryCodingKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Matches decoded alias pages back to their (repo, reason). Pure —
    /// unit-tested with a fixture.
    static func parseActivityResponse(
        _ envelope: GraphQLActivityEnvelope,
        aliases: [(alias: String, repo: GitHubRepo, reason: ActivityReason)]
    ) -> [GitHubActivityHit] {
        guard let data = envelope.data else { return [] }
        var hits: [GitHubActivityHit] = []
        for alias in aliases {
            for node in data.pages[alias.alias] ?? [] {
                hits.append(GitHubActivityHit(repo: alias.repo, reason: alias.reason, issue: node.issue))
            }
        }
        return hits
    }

    // MARK: API: issue events (what changed, and who did it)

    struct GitHubIssueEvent: Decodable, Hashable {
        let id: Int64
        let event: String
        let actor: GitHubUser?
        /// Who was assigned, for "assigned" events.
        let assignee: GitHubUser?
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, event, actor, assignee
            case createdAt = "created_at"
        }

        /// Events that represent a real change to the issue (for the
        /// activity feed's "someone else updated my ticket"). Mentions and
        /// references have their own feed reasons; cross-references are
        /// noise. Assignment is handled separately (self-assign filtering).
        static let changeEvents: Set<String> = [
            "labeled", "unlabeled", "milestoned", "demilestoned",
            "renamed", "closed", "reopened", "merged",
            "head_ref_deleted", "head_ref_restored",
            "locked", "unlocked", "pinned", "unpinned", "transferred",
            "review_requested", "review_request_removed",
        ]
    }

    /// Timeline events for one issue/PR (first page, 100 events).
    func issueEvents(owner: String, repo: String, number: Int) async throws -> [GitHubIssueEvent] {
        let path = try repoPath(owner: owner, repo: repo) + "/issues/\(number)/events?per_page=100"
        return try await send(request("GET", path), as: [GitHubIssueEvent].self)
    }
}