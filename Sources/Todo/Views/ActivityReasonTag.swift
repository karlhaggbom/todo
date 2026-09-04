import SwiftUI

/// Small capsule describing why an issue is in the activity feed:
/// reason, actor (when known), and relative time of the activity.
struct ActivityReasonTag: View {
    let reason: ActivityReason
    let actor: String?
    let at: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(label)
            if let when = whenText {
                Text(when)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
        .help(reason.help)
    }

    private var icon: String {
        switch reason {
        case .mention: return "at"
        case .assigned: return "person.crop.circle.badge.checkmark"
        case .comment: return "text.bubble"
        case .change: return "pencil.line"
        case .reviewRequested: return "eye"
        }
    }

    private var label: String {
        switch reason {
        case .mention:
            return "Mentioned you"
        case .assigned:
            return actor.map { "Assigned by \($0)" } ?? "Assigned to you"
        case .comment:
            return actor.map { "Comment by \($0)" } ?? "New comment"
        case .change:
            return actor.map { "Updated by \($0)" } ?? "Updated"
        case .reviewRequested:
            return "Review requested"
        }
    }

    /// "3h ago" / "2d ago"; nil when the timestamp can't be parsed.
    private var whenText: String? {
        guard let date = parseActivityDate(at) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private extension ActivityReason {
    var help: String {
        switch self {
        case .mention: return "You were mentioned"
        case .assigned: return "Assigned to you"
        case .comment: return "Someone commented on your issue"
        case .change: return "Someone updated your issue"
        case .reviewRequested: return "Your review is requested"
        }
    }
}