import SwiftUI
import AppKit

// MARK: - Issue detail (GitHub)

struct GitHubIssueDetailView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    let board: GitHubBoardModel
    let issue: GitHubIssue

    @State private var detail: GitHubIssue?
    @State private var comments: [GitHubComment] = []
    @State private var newComment = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var allUsers: [GitHubUser] = []   // collaborators, cached
    @State private var usersLoaded = false
    @State private var mentionFilter: String?       // nil = not in @-mention mode
    @State private var mentionSelection = 0         // active row in dropdown
    @State private var mentionKeyMonitor: Any?
    @State private var statusBanner: String?

    private var currentIssue: GitHubIssue { detail ?? issue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = loadError {
                errorView(error)
            } else if isLoading {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                Spacer()
            } else {
                content
            }
        }
        .frame(width: 480, height: 560)
        .task { await load() }
        .onAppear { installMentionKeyMonitor() }
        .onDisappear { removeMentionKeyMonitor() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("#\(currentIssue.number)")
                .font(.system(size: 14, weight: .bold).monospaced())
                .foregroundStyle(.tint)
            Text(currentIssue.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            stateCapsule
        }
        .padding(12)
    }

    private var stateCapsule: some View {
        let (text, color): (String, Color) = {
            switch currentIssue.laneID {
            case GitHubLane.completed.id: return ("Completed", .green)
            case GitHubLane.notPlanned.id: return ("Not Planned", .gray)
            default: return ("Open", .blue)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: Body

    private func errorView(_ message: String) -> some View {
        ErrorBanner(message: message, onDismiss: {
            loadError = nil
            Task { await load() }
        })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = statusBanner {
                Text(banner)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    transitionPicker

                    if let body = currentIssue.body?.nilIfBlank {
                        Text("Description")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(body.ghAttributed)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Comments")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("@\(comment.user.login)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tint)
                                Text(shortDate(comment.createdAt))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(comment.body.ghAttributed)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                    }
                }
                .padding(12)
            }
            commentComposer
        }
    }

    /// Lane transitions. GitHub has no workflow engine — state changes are
    /// direct: open, close-as-completed, close-as-not-planned.
    private var transitionPicker: some View {
        HStack(spacing: 6) {
            transitionButton(GitHubLane.open, label: "Reopen", systemImage: "arrow.clockwise.circle")
            transitionButton(GitHubLane.completed, label: "Complete", systemImage: "checkmark.circle")
            transitionButton(GitHubLane.notPlanned, label: "Not Planned", systemImage: "xmark.circle")
            Spacer()
            if let url = currentIssue.htmlURL, let target = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(target)
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Open in Browser")
            }
        }
    }

    private func transitionButton(_ lane: GitHubLane, label: String, systemImage: String) -> some View {
        let isCurrent = currentIssue.laneID == lane.id
        return Button {
            Task { await transition(to: lane) }
        } label: {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isCurrent)
        .opacity(isCurrent ? 0.4 : 1)
    }

    // MARK: Comment composer with @mentions

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            mentionDropdown
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $newComment)
                    .font(.system(size: 12))
                    .frame(height: 52)
                    .scrollContentBackground(.hidden)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    )
                    .onChange(of: newComment) { _ in updateMentionState() }

                Button("Comment") {
                    Task { await sendComment() }
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }

    /// Inline @-mention dropdown: while the comment ends in an active
    /// `@query` token, show collaborators whose login starts with the query.
    @ViewBuilder
    private var mentionDropdown: some View {
        if mentionFilter != nil, !filteredUsers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredUsers.enumerated()), id: \.element.login) { index, user in
                            Button {
                                insertMention(user)
                            } label: {
                                HStack {
                                    Text(user.name ?? user.login)
                                        .font(.system(size: 12))
                                        .foregroundStyle(index == mentionSelection ? Color.accentColor : Color.primary)
                                    Spacer()
                                    Text("@\(user.login)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                index == mentionSelection
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear
                            )
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 140)
                Text("Tab cycles · Enter inserts · Esc cancels")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private var filteredUsers: [GitHubUser] {
        guard let f = mentionFilter else { return [] }
        guard !f.isEmpty else { return allUsers }
        return allUsers.filter { $0.login.range(of: f, options: [.caseInsensitive, .anchored], locale: .current) != nil }
    }

    /// Enter @-mention mode when the text ends in an unfinished `@token`
    /// that starts a word. Any whitespace (or no `@`) exits the mode.
    private func updateMentionState() {
        let text = newComment
        guard let atRange = text.range(of: "@", options: .backwards) else {
            mentionFilter = nil
            return
        }
        if atRange.lowerBound > text.startIndex,
           !text[text.index(before: atRange.lowerBound)].isWhitespace {
            mentionFilter = nil
            return
        }
        let tail = text[atRange.upperBound...]
        if tail.contains(where: { $0.isWhitespace }) {
            mentionFilter = nil
        } else {
            mentionFilter = String(tail)
            mentionSelection = 0
            if !usersLoaded {
                usersLoaded = true
                Task { @MainActor in
                    allUsers = (try? await board.client.collaborators(
                        owner: board.repo.owner, repo: board.repo.repo
                    )) ?? []
                }
            }
        }
    }

    /// Tab / ⇧Tab cycle dropdown rows, Enter inserts the selected mention,
    /// Esc cancels. Runs before the global monitor so these keys work while
    /// the comment TextEditor is first responder.
    private func installMentionKeyMonitor() {
        guard mentionKeyMonitor == nil else { return }
        mentionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard mentionFilter != nil else { return event }
            let users = filteredUsers
            guard !users.isEmpty else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "\t":
                let delta = event.modifierFlags.contains(.shift) ? -1 : 1
                mentionSelection = (mentionSelection + delta + users.count) % users.count
                return nil
            case "\r", "\n":
                insertMention(users[users.indices.contains(mentionSelection) ? mentionSelection : 0])
                return nil
            case "\u{1b}":
                mentionFilter = nil
                return nil
            default:
                return event
            }
        }
    }

    private func removeMentionKeyMonitor() {
        if let m = mentionKeyMonitor {
            NSEvent.removeMonitor(m)
            mentionKeyMonitor = nil
        }
    }

    private func insertMention(_ user: GitHubUser) {
        // Replace the typed `@query` token with the real @login. GitHub
        // mentions are plain markdown — no send-time conversion needed.
        if let atRange = newComment.range(of: "@", options: .backwards) {
            newComment = String(newComment[..<atRange.lowerBound]) + "@\(user.login) "
        } else {
            newComment += "@\(user.login) "
        }
        mentionFilter = nil
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        do {
            async let detailTask = board.client.issue(owner: board.repo.owner, repo: board.repo.repo, number: issue.number)
            async let commentsTask = board.client.comments(owner: board.repo.owner, repo: board.repo.repo, number: issue.number)
            let (d, c) = try await (detailTask, commentsTask)
            detail = d
            comments = c
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func transition(to lane: GitHubLane) async {
        if await board.transition(issueNumber: issue.number, toLane: lane.id) {
            statusBanner = "Moved to \(lane.name)"
            await load()
        }
    }

    private func sendComment() async {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if await board.addComment(issueNumber: issue.number, body: text) {
            newComment = ""
            mentionFilter = nil
            statusBanner = nil
            if let refreshed = try? await board.client.comments(owner: board.repo.owner, repo: board.repo.repo, number: issue.number) {
                comments = refreshed
            }
        }
    }

    private func shortDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: iso) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return iso
    }
}

// MARK: - GitHub mention styling

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

extension String {
    /// GitHub comments are plain markdown. We don't render markdown, but we
    /// do style @mentions bold + blue, matching the Jira detail view.
    var ghAttributed: AttributedString {
        var result = AttributedString()
        let pattern = try! NSRegularExpression(pattern: "@([A-Za-z0-9][A-Za-z0-9-]{0,38})")
        let ns = NSString(string: self)
        let matches = pattern.matches(in: self, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        for match in matches {
            // Only treat @login as a mention at a word boundary.
            let matchStart = match.range.location
            let before = matchStart == 0 ? nil : ns.substring(with: NSRange(location: matchStart - 1, length: 1))
            if let before, !before.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                continue
            }
            if matchStart > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: matchStart - cursor)))
            }
            var mention = AttributedString(ns.substring(with: match.range))
            mention.inlinePresentationIntent = .stronglyEmphasized
            mention.foregroundColor = Color(nsColor: .linkColor)
            result += mention
            cursor = matchStart + match.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }
}