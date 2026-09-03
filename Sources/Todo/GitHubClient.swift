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

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid GitHub URL"
        case .http(let code, let body): return "GitHub HTTP \(code): \(body.prefix(300))"
        case .decode(let m): return "GitHub decode error: \(m)"
        case .noToken: return "Missing GitHub token in Keychain"
        case .badRepo: return "Invalid repository"
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

    /// Users who can be mentioned in this repo (collaborators).
    func collaborators(owner: String, repo: String) async throws -> [GitHubUser] {
        let path = try repoPath(owner: owner, repo: repo) + "/collaborators?per_page=100"
        return try await send(request("GET", path), as: [GitHubUser].self)
    }

    /// Issues in a repo that mention the given login (search API).
    func issuesMentioning(owner: String, repo: String, login: String) async throws -> [GitHubIssue] {
        let q = "repo:\(owner)/\(repo)+is:issue+mentions:\(login)"
        let path = "/search/issues?q=\(q)&per_page=50&sort=updated"
        struct Result: Decodable { let items: [GitHubIssue] }
        let result: Result = try await send(request("GET", path), as: Result.self)
        return result.items.filter { $0.pullRequest == nil }
    }
}