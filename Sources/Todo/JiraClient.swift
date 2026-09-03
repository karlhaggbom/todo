import Foundation

// MARK: - Jira REST client (basic auth: email + API token)

struct JiraCredentials {
    let baseURL: String
    let email: String
    let apiToken: String
}

enum JiraError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)
    case noToken
    case ambiguousTransition(names: [String])
    case noTransition

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid Jira URL"
        case .http(let code, let body): return "Jira HTTP \(code): \(body.prefix(300))"
        case .decode(let m): return "Jira decode error: \(m)"
        case .noToken: return "Missing API token in Keychain"
        case .ambiguousTransition(let names): return "Multiple transitions match: \(names.joined(separator: ", "))"
        case .noTransition: return "No matching transition"
        }
    }
}

final class JiraClient {
    let credentials: JiraCredentials
    private let session: URLSession

    init(credentials: JiraCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    // MARK: Plumbing

    private func base() throws -> String {
        var url = credentials.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        guard URL(string: url) != nil else { throw JiraError.badURL }
        return url
    }

    private func authHeader() throws -> String {
        let raw = "\(credentials.email):\(credentials.apiToken)"
        let data = Data(raw.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) throws -> URLRequest {
        guard let url = URL(string: try base() + path) else { throw JiraError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw JiraError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JiraError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Include a raw-body snippet so decode failures are diagnosable
            // (and copyable via the error banner's Copy button).
            let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw JiraError.decode("while decoding \(T.self): \(error) — response body: \(body.prefix(400))")
        }
    }

    private func jsonBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: API: identity

    func myself() async throws -> JiraUser {
        try await send(try request("GET", "/rest/api/3/myself"), as: JiraUser.self)
    }

    // MARK: API: search issues (JQL)

    struct SearchRequest: Encodable {
        let jql: String
        let maxResults: Int
        let fields: [String]
        var nextPageToken: String?
    }

    struct SearchResponse: Decodable {
        struct ResultIssue: Decodable {
            let key: String
            let fields: Fields
        }
        struct Fields: Decodable {
            let summary: String?
            let description: ADFDocument?
            let status: Status
            let issuetype: IssueType
            let updated: String?
            struct Status: Decodable {
                let name: String
                let statusCategory: Category
                struct Category: Decodable { let key: String }
            }
            struct IssueType: Decodable {
                let name: String
                let iconURL: String?
                enum CodingKeys: String, CodingKey { case name; case iconURL = "iconUrl" }
            }
        }
        let issues: [ResultIssue]?
        let nextPageToken: String?
        let total: Int?
    }

    func search(jql: String, maxResults: Int = 100, fields: [String] = ["summary", "description", "status", "issuetype", "updated"]) async throws -> SearchResponse {
        let body = try jsonBody(SearchRequest(jql: jql, maxResults: maxResults, fields: fields, nextPageToken: nil))
        let req = try request("POST", "/rest/api/3/search/jql", body: body)
        return try await send(req, as: SearchResponse.self)
    }

    // MARK: API: statuses for a project (lane fallback)

    // GET /rest/api/3/project/{key}/statuses returns a *top-level array*
    // of issue-type entries, each carrying a `statuses` list.
    struct StatusesForIssueType: Decodable {
        let statuses: [ProjectStatus]
    }
    struct ProjectStatus: Decodable {
        let name: String
        // Some Jira deployments omit statusCategory here; tolerate it.
        let statusCategory: Category?
        struct Category: Decodable { let key: String? }
    }

    /// Distinct statuses for a project ordered by status category.
    func projectStatuses(projectKey: String) async throws -> [JiraStatus] {
        let req = try request("GET", "/rest/api/3/project/\(projectKey)/statuses")
        let groups = try await send(req, as: [StatusesForIssueType].self)
        var seen = Set<String>()
        var result: [JiraStatus] = []
        for group in groups {
            for s in group.statuses where seen.insert(s.name).inserted {
                result.append(JiraStatus(name: s.name, categoryKey: s.statusCategory?.key ?? "indeterminate"))
            }
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: API: single issue (with description)

    struct IssueResponse: Decodable {
        let key: String
        let fields: JiraIssue.Fields
    }

    func issue(key: String) async throws -> IssueResponse {
        let req = try request("GET", "/rest/api/3/issue/\(key)?fields=summary,description,status,issuetype,assignee,priority,updated")
        return try await send(req, as: IssueResponse.self)
    }

    // MARK: API: transitions

    struct TransitionsResponse: Decodable {
        let transitions: [JiraTransition]
    }

    func transitions(key: String) async throws -> [JiraTransition] {
        let req = try request("GET", "/rest/api/3/issue/\(key)/transitions")
        let resp = try await send(req, as: TransitionsResponse.self)
        return resp.transitions
    }

    struct TransitionPayload: Encodable {
        struct Transition: Encodable { let id: String }
        let transition: Transition
    }

    func applyTransition(key: String, transitionID: String) async throws {
        let body = try jsonBody(TransitionPayload(transition: .init(id: transitionID)))
        let req = try request("POST", "/rest/api/3/issue/\(key)/transitions", body: body)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JiraError.http(code, "transition failed")
        }
    }

    /// Apply the single transition leading to `statusName`. Throws when ambiguous or missing.
    func transitionTo(key: String, statusName: String) async throws {
        let all = try await transitions(key: key)
        let matches = all.filter { $0.to.name == statusName }
        switch matches.count {
        case 1:
            try await applyTransition(key: key, transitionID: matches[0].id)
        case 0:
            throw JiraError.noTransition
        default:
            throw JiraError.ambiguousTransition(names: matches.map(\.name))
        }
    }

    // MARK: API: comments

    func comments(key: String) async throws -> JiraCommentPage {
        let req = try request("GET", "/rest/api/3/issue/\(key)/comment")
        return try await send(req, as: JiraCommentPage.self)
    }

    struct CommentPayload: Encodable {
        let body: ADFDocument
    }

    func addComment(key: String, body: ADFDocument) async throws {
        let data = try jsonBody(CommentPayload(body: body))
        let req = try request("POST", "/rest/api/3/issue/\(key)/comment", body: data)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JiraError.http(code, "comment failed")
        }
    }

    // MARK: API: assignable users (for @mentions)

    func assignableUsers(projectKey: String, query: String? = nil) async throws -> [JiraUser] {
        var path = "/rest/api/3/user/assignable/search?project=\(projectKey)&maxResults=50"
        if let query, !query.isEmpty {
            path += "&query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        }
        let req = try request("GET", path)
        return try await send(req, as: [JiraUser].self)
    }

    // MARK: API: attachments

    struct AttachmentResponse: Decodable {
        let id: String
        let filename: String
    }

    /// Upload a file as an attachment. Returns the attachment filename.
    func addAttachment(key: String, fileURL: URL) async throws -> String {
        let boundary = "todo-\(UUID().uuidString)"
        var req = try request("POST", "/rest/api/3/issue/\(key)/attachments")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        let filename = fileURL.lastPathComponent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JiraError.http(code, String(data: data, encoding: .utf8) ?? "attachment failed")
        }
        let decoded = try? JSONDecoder().decode([AttachmentResponse].self, from: data)
        return decoded?.first?.filename ?? filename
    }
}