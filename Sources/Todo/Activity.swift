import Foundation

// MARK: - Activity feed types
//
// The activity feed aggregates everything that impacts the user across
// Jira and GitHub: mentions, assignments, others' comments and changes on
// their tickets, and (GitHub) PR review requests. Each entry is an issue
// with a single best "reason" — the most recent relevant activity.

/// Why an issue appears in the activity feed.
enum ActivityReason: String, Codable, Hashable {
    case mention
    case assigned
    case comment
    case change
    case reviewRequested
}

/// Jira timestamps arrive as "2026-09-04T08:00:00.000+0000" (fractional,
/// colon-less offset) and GitHub's as "2026-09-04T08:00:00Z". Parse both,
/// plus plain milliseconds, so feed ordering works without caring which
/// API produced the string. Returns nil for anything undecodable — callers
/// treat that as "sort last".
func parseActivityDate(_ iso: String) -> Date? {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "UTC")
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",   // Jira
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",  // GitHub with fraction
        "yyyy-MM-dd'T'HH:mm:ssZ",        // GitHub / Jira without fraction
        "yyyy-MM-dd'T'HH:mm:ss.SSSXX",
    ]
    for format in formats {
        parser.dateFormat = format
        if let date = parser.date(from: iso) {
            return date
        }
    }
    // ISO8601DateFormatter as a last resort (handles "Z" natively).
    let isoParser = ISO8601DateFormatter()
    return isoParser.date(from: iso)
}

/// One Jira issue in the activity feed, with the reason it's here.
struct JiraActivityEntry: Codable, Identifiable, Hashable {
    var reason: ActivityReason
    let issue: JiraIssue
    /// Raw API timestamp of the activity (or the issue's updated time when
    /// the reason has no finer-grained timestamp, e.g. mentions).
    let activityAt: String
    /// Who performed the activity, when we know it (comments, changes).
    var actor: String?

    var id: String { issue.key }
    /// Read tracking is per-activity, not per-issue: the key includes the
    /// activity timestamp, so a NEW comment/change on an already-read
    /// issue surfaces as unread again.
    var readKey: String { "\(issue.key)@\(activityAt)" }

    /// Keeps the entry whose activity is more recent; undecodable
    /// timestamps lose to decodable ones.
    static func newest(_ a: JiraActivityEntry, _ b: JiraActivityEntry) -> JiraActivityEntry {
        switch (parseActivityDate(a.activityAt), parseActivityDate(b.activityAt)) {
        case let (x?, y?): return x >= y ? a : b
        case (nil, _): return b
        default: return a
        }
    }
}

/// One GitHub issue/PR in the activity feed, with its repo for context.
struct GitHubActivityEntry: Codable, Identifiable, Hashable {
    var reason: ActivityReason
    let repo: GitHubRepo
    let issue: GitHubIssue
    let activityAt: String
    var actor: String?

    var id: String { "\(repo.id)-\(issue.number)" }
    /// Same per-activity scheme as the Jira feed, anchored on the stable
    /// "owner/repo#number" base so the key survives repo re-adds.
    var readKey: String { "\(repo.owner)/\(repo.repo)#\(issue.number)@\(activityAt)" }

    static func newest(_ a: GitHubActivityEntry, _ b: GitHubActivityEntry) -> GitHubActivityEntry {
        switch (parseActivityDate(a.activityAt), parseActivityDate(b.activityAt)) {
        case let (x?, y?): return x >= y ? a : b
        case (nil, _): return b
        default: return a
        }
    }
}