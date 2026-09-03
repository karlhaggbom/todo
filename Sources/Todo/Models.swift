import Foundation

// MARK: - Core models

struct Lane: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var name: String
    var position: Double
}

struct TodoTask: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var laneID: Int64
    var title: String
    var notes: String
    var position: Double
    var createdAt: Date
    var completedAt: Date?
}

// MARK: - Jira models

struct JiraAccount: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var name: String     // display name chosen by user
    var email: String
    var baseURL: String  // e.g. https://yourorg.atlassian.net
}

struct JiraSpace: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var accountID: Int64
    var name: String     // display name
    var projectKey: String
    var jql: String?     // optional custom JQL; nil = project = KEY
}

// MARK: - Jira API response models

struct JiraUser: Codable, Identifiable, Hashable {
    let accountID: String
    let displayName: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case displayName
        case avatarURL = "avatarUrls"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID)
        displayName = try c.decode(String.self, forKey: .displayName)
        let urls = try? c.decode([String: String].self, forKey: .avatarURL)
        avatarURL = urls?["48x48"] ?? urls?["32x32"] ?? urls?.values.first
    }

    init(accountID: String, displayName: String, avatarURL: String? = nil) {
        self.accountID = accountID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    var id: String { accountID }
}

struct JiraIssue: Codable, Identifiable, Hashable {
    struct Fields: Codable, Hashable {
        struct Status: Codable, Hashable {
            var name: String
            var statusCategory: StatusCategory
            struct StatusCategory: Codable, Hashable {
                var key: String // "new", "indeterminate", "done"
            }
        }
        struct IssueType: Codable, Hashable {
            var name: String
            var iconURL: String?
            enum CodingKeys: String, CodingKey {
                case name
                case iconURL = "iconUrl"
            }
        }
        struct Assignee: Codable, Hashable {
            var displayName: String?
        }
        struct Priority: Codable, Hashable {
            var name: String?
        }

        var summary: String
        var description: ADFDocument?
        var status: Status
        var issuetype: IssueType
        var assignee: Assignee?
        var priority: Priority?
        var updated: String?
    }

    var key: String
    var fields: Fields

    var id: String { key }
}

struct JiraStatus: Identifiable, Hashable {
    let name: String
    let categoryKey: String // new | indeterminate | done
    var id: String { name }

    /// Sort order for lane arrangement: todo → in progress → done.
    var sortOrder: Int {
        switch categoryKey {
        case "new": return 0
        case "indeterminate": return 1
        case "done": return 2
        default: return 3
        }
    }
}

struct JiraTransition: Codable, Identifiable, Hashable {
    struct To: Codable, Hashable { let name: String, id: String }
    let id: String
    let name: String
    let to: To
}

struct JiraCommentPage: Codable, Hashable {
    struct Comment: Codable, Identifiable, Hashable {
        struct Author: Codable, Hashable {
            let displayName: String
        }
        let id: String
        let author: Author?
        let body: ADFDocument
        let created: String
    }
    let comments: [Comment]
    let total: Int
}

struct JiraSearchResult: Codable {
    struct ResultIssue: Codable {
        let key: String
        let fields: Fields
    }
    struct Fields: Codable {
        let summary: String?
        let status: IssueStatus
        let issuetype: IssueType
        let updated: String?
        let description: ADFDocument?
    }
    struct IssueStatus: Codable {
        let name: String
        let statusCategory: Category
        struct Category: Codable {
            let key: String
        }
    }
    struct IssueType: Codable {
        let name: String
    }
    let issues: [ResultIssue]?
}

// MARK: - ADF (Atlassian Document Format)

/// A loose representation of an Atlassian Document Format node tree, plus
/// conversion to plain text for display.
struct ADFDocument: Codable, Hashable {
    var type: String
    var version: Int?
    var content: [ADFNode]?

    init(type: String = "doc", version: Int = 1, content: [ADFNode]?) {
        self.type = type
        self.version = version
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? "doc"
        version = try? c.decode(Int.self, forKey: .version)
        content = try? c.decode([ADFNode].self, forKey: .content)
    }

    /// Plain text rendering (mentions become @Name).
    var plainText: String {
        content?.map(\.plainText).joined(separator: "\n") ?? ""
    }

    /// Build a simple paragraph document from plain text.
    static func paragraphs(from text: String) -> ADFDocument {
        let paras = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let nodes: [ADFNode] = paras.map { line in
            if line.isEmpty {
                return ADFNode(type: "paragraph", content: [])
            }
            return ADFNode(
                type: "paragraph",
                content: [ADFNode(type: "text", text: String(line))]
            )
        }
        return ADFDocument(content: nodes.isEmpty ? [ADFNode(type: "paragraph", content: [])] : nodes)
    }
}

struct ADFNode: Codable, Hashable {
    var type: String?
    var text: String?
    var attrs: [String: ADFAttrValue]?
    var content: [ADFNode]?

    init(type: String? = nil, text: String? = nil, attrs: [String: ADFAttrValue]? = nil, content: [ADFNode]? = nil) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decode(String.self, forKey: .type)
        text = try? c.decode(String.self, forKey: .text)
        attrs = try? c.decode([String: ADFAttrValue].self, forKey: .attrs)
        content = try? c.decode([ADFNode].self, forKey: .content)
    }

    var plainText: String {
        if type == "mention" {
            // Jira Cloud sends `text` ("@Name"); tolerate `displayName` too.
            if let text = attrs?["text"]?.stringValue { return text.hasPrefix("@") ? text : "@\(text)" }
            if let name = attrs?["displayName"]?.stringValue { return "@\(name)" }
            if let id = attrs?["id"]?.stringValue { return "@\(id)" }
        }
        if type == "hardBreak" { return "\n" }
        if let text { return text }
        return content?.map(\.plainText).joined() ?? ""
    }

    /// Jira Cloud mention node: attrs carry the account id and `text`
    /// ("@Name") — `text` is the documented, validated attribute.
    static func mention(userID: String, displayName: String) -> ADFNode {
        ADFNode(
            type: "mention",
            attrs: [
                "id": .string(userID),
                "text": .string("@\(displayName)"),
            ]
        )
    }
}

/// JSON value union for ADF attrs (only what we need: strings and ints).
enum ADFAttrValue: Codable, Hashable {
    case string(String)
    case int(Int)

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string("") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        }
    }
}
// MARK: - GitHub models

struct GitHubAccount: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var name: String     // display name chosen by user
    var baseURL: String  // https://api.github.com (or https://host/api/v3 for GHE)
    var login: String    // the authenticated user's GitHub login
}

struct GitHubRepo: Identifiable, Codable, Equatable, Hashable {
    var id: Int64
    var accountID: Int64
    var name: String     // display name
    var owner: String    // repo owner (org or user)
    var repo: String     // repo name
}

// MARK: - GitHub API response models

struct GitHubUser: Codable, Identifiable, Hashable {
    let login: String
    let name: String?

    var id: String { login }
}

struct GitHubIssue: Codable, Identifiable, Hashable {
    let number: Int
    let title: String
    let body: String?
    let state: String                       // "open" | "closed"
    let stateReason: String?                // "completed" | "not_planned" | "reopened" | nil
    let htmlURL: String?
    let updatedAt: String
    let labels: [GitHubLabel]
    /// Present (non-nil) when the item is actually a pull request.
    let pullRequest: GitHubPullRequestMarker?

    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, labels
        case stateReason = "state_reason"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    /// The lane this issue belongs to on the board.
    var laneID: String {
        if state == "open" { return "open" }
        return stateReason == "not_planned" ? "not_planned" : "completed"
    }
}

struct GitHubLabel: Codable, Hashable {
    let name: String
    let color: String
}

struct GitHubPullRequestMarker: Codable, Hashable {}

struct GitHubComment: Codable, Identifiable, Hashable {
    let id: Int
    let body: String
    let user: GitHubUser
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
