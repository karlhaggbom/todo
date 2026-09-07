import SwiftUI

// MARK: - Ticket detail (Jira issue)

struct TicketDetailView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let account: JiraAccount
    let board: JiraBoardModel
    let issue: JiraIssue

    @State private var detail: JiraClient.IssueResponse?
    @State private var comments: [JiraCommentPage.Comment] = []
    @State private var newComment = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var transitions: [JiraTransition] = []
    @State private var allUsers: [JiraUser] = []   // assignable users, cached
    @State private var usersLoaded = false
    @State private var mentionFilter: String?       // nil = not in @-mention mode
    @State private var editingCommentID: String?
    @State private var editCommentText = ""
    /// Created-timestamp of the comment that triggered this activity —
    /// the detail view accents it (and the activity pages mark the
    /// issue read when the sheet closes). nil when opened from a board.
    var highlightCommentAt: String? = nil

    /// Mentions recovered from the comment being edited so untouched
    /// @Name tokens re-encode as real mention nodes on save.
    @State private var editMentions: [String: String] = [:]
    @State private var mentionSelection = 0         // active row in dropdown
    @State private var mentionKeyMonitor: Any?
    @State private var attachmentURL: URL?
    @State private var statusBanner: String?
    @State private var pendingMentions: [String: String] = [:]

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
            Text(issue.key)
                .font(.system(size: 14, weight: .bold).monospaced())
                .foregroundStyle(.tint)
            Text(detail?.fields.summary ?? issue.fields.summary)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button("Edit") {
                dismiss()
                // Sheets are presented from RootView and mutually exclusive —
                // set the edit target one tick later, after this sheet is gone.
                DispatchQueue.main.async {
                    appModel.editTarget = EditIssueTarget(content: .jiraIssue(
                        account: account, board: board,
                        issue: JiraIssue(key: issue.key, fields: detail?.fields ?? issue.fields)
                    ))
                }
            }
            .buttonStyle(.borderless)
            if let status = detail?.fields.status {
                Text(status.name)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let banner = statusBanner {
                        Label(banner, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
                    }

                    section("Transitions") {
                        FlowButtons(transitions: transitions) { transition in
                            Task { await apply(transition) }
                        }
                    }

                    if let description = detail?.fields.description, !description.plainText.isEmpty {
                        section("Description") {
                            Text(description.plainText)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                    }

                    section("Comments (\(comments.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(comments.reversed()) { comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(comment.author?.displayName ?? "Someone")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(shortDate(comment.created))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                        if editingCommentID == comment.id {
                                            Text("editing")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    if editingCommentID == comment.id {
                                        TextEditor(text: $editCommentText)
                                            .font(.system(size: 12))
                                            .frame(minWidth: 220, minHeight: 44, alignment: .leading)
                                            .scrollContentBackground(.hidden)
                                            .padding(4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color(nsColor: .textBackgroundColor))
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                        HStack(spacing: 8) {
                                            Button("Save") {
                                                Task { await saveEditedComment(comment) }
                                            }
                                            .controlSize(.small)
                                            .help("Save edited comment (⌘⏎)")
                                            Button("Cancel") {
                                                editingCommentID = nil
                                            }
                                            .controlSize(.small)
                                            Spacer()
                                        }
                                    } else {
                                        Text(comment.body.attributed)
                                            .font(.system(size: 12))
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(comment.created == highlightCommentAt
                                              ? Color.accentColor.opacity(0.08)
                                              : Color(nsColor: .controlBackgroundColor))
                                )
                                // The comment that surfaced this issue in the
                                // activity feed: accent ring + left bar.
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(comment.created == highlightCommentAt
                                                ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
                                )
                                .overlay(alignment: .leading) {
                                    if comment.created == highlightCommentAt {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.accentColor)
                                            .frame(width: 3)
                                            .padding(.vertical, 3)
                                    }
                                }
                                .id(comment.id)
                                .contextMenu {
                                    Button("Edit Comment…") {
                                        startEditingComment(comment)
                                    }
                                    Button("Delete Comment", role: .destructive) {
                                        Task { await deleteComment(comment) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            // Once comments load, bring the highlighted comment into
            // view — a long description or comment history can push it
            // below the fold. Newest-first order usually puts it at the
            // top of the list already, so this is just insurance.
            .onChange(of: comments, initial: true) { _, _ in
                guard let at = highlightCommentAt,
                      let match = comments.first(where: { $0.created == at }) else { return }
                // The sheet content only mounts after load() finishes
                // (loading spinner branch), so a plain onChange would miss
                // the initial set — `initial: true` fires on appearance.
                // And scrollTo during the same transaction no-ops — the
                // rows have no geometry yet — so give layout a beat.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    proxy.scrollTo(match.id, anchor: .top)
                }
            }
            }

            commentComposer
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    // MARK: Comment composer with @mentions + attachment

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            mentionDropdown
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Task {
                            if await board.addAttachment(issueKey: issue.key, fileURL: url) {
                                statusBanner = "Attached \(url.lastPathComponent)"
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Attach a file")

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
                .help("Send comment (⌘↩)")
            }
            .padding(10)
        }
    }

    /// Inline @-mention dropdown: while the comment ends in an active
    /// `@query` token, show assignable users whose name starts with the query.
    @ViewBuilder
    private var mentionDropdown: some View {
        if mentionFilter != nil, !filteredUsers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredUsers.enumerated()), id: \.element.accountID) { index, user in
                            Button {
                                insertMention(user)
                            } label: {
                                HStack {
                                    Text(user.displayName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(index == mentionSelection ? Color.accentColor : Color.primary)
                                    Spacer()
                                    Text(mentionFilter ?? "")
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

    private var filteredUsers: [JiraUser] {
        guard let f = mentionFilter else { return [] }
        guard !f.isEmpty else { return allUsers }
        return allUsers.filter { $0.displayName.range(of: f, options: [.caseInsensitive, .anchored], locale: .current) != nil }
    }

    /// Enter @-mention mode when the text ends in an unfinished `@token`
    /// that starts a word. Any whitespace (or no `@`) exits the mode, leaving
    /// the typed text as plain comment text.
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
                    allUsers = (try? await board.client.assignableUsers(
                        projectKey: board.space.projectKey
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
            // ⌘Enter sends the comment from anywhere in the composer — even
            // mid-typing an @mention query, since ⌘ makes the intent explicit.
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               chars == "\r" || chars == "\n" {
                if let id = editingCommentID,
                   !editCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { @MainActor in
                        if let comment = comments.first(where: { $0.id == id }) {
                            await saveEditedComment(comment)
                        }
                    }
                    return nil
                }
                guard !newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return event
                }
                Task { @MainActor in await sendComment() }
                return nil
            }
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

    private func insertMention(_ user: JiraUser) {
        // Replace the typed `@query` token with the real mention.
        if let atRange = newComment.range(of: "@", options: .backwards) {
            newComment = String(newComment[..<atRange.lowerBound]) + "@\(user.displayName) "
        } else {
            newComment += "@\(user.displayName) "
        }
        mentionFilter = nil
        // Remember mention for send-time conversion: @Name → mention node.
        pendingMentions[user.displayName] = user.accountID
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        do {
            async let detailTask = board.client.issue(key: issue.key)
            async let commentsTask = board.client.comments(key: issue.key)
            async let transitionsTask = board.client.transitions(key: issue.key)
            let (d, c, t) = try await (detailTask, commentsTask, transitionsTask)
            detail = d
            comments = c.comments
            transitions = t
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(_ transition: JiraTransition) async {
        if await board.transition(issueKey: issue.key, toStatus: transition.to.name) {
            statusBanner = "Moved to \(transition.to.name)"
            await load()
        }
    }

    private func startEditingComment(_ comment: JiraCommentPage.Comment) {
        editCommentText = comment.body.plainText
        editMentions = Self.mentions(in: comment.body)
        editingCommentID = comment.id
    }

    /// displayName → accountID for every mention node in the document, so an
    /// edited comment preserves untouched mentions as real mention nodes.
    private static func mentions(in doc: ADFDocument) -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ nodes: [ADFNode]?) {
            for node in nodes ?? [] {
                if node.type == "mention",
                   let accountID = node.attrs?["id"]?.stringValue,
                   let name = (node.attrs?["text"]?.stringValue ?? node.attrs?["displayName"]?.stringValue)?
                       .trimmingCharacters(in: CharacterSet(charactersIn: "@")) {
                    result[name] = accountID
                }
                walk(node.content)
            }
        }
        walk(doc.content)
        return result
    }

    private func saveEditedComment(_ comment: JiraCommentPage.Comment) async {
        let text = editCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let doc = ADFBuilder.comment(from: text, mentions: editMentions)
        if await board.editComment(issueKey: issue.key, id: comment.id, body: doc) {
            editingCommentID = nil
            statusBanner = nil
            if let page = try? await board.client.comments(key: issue.key) {
                comments = page.comments
            }
        } else {
            statusBanner = "Couldn't update comment: \(board.lastError ?? "unknown error")"
        }
    }

    private func deleteComment(_ comment: JiraCommentPage.Comment) async {
        // Optimistic: remove immediately, restore at the same spot on failure.
        let index = comments.firstIndex { $0.id == comment.id }
        if let index { comments.remove(at: index) }
        if await board.deleteComment(issueKey: issue.key, id: comment.id) {
            statusBanner = nil
        } else {
            if let index { comments.insert(comment, at: index) }
            statusBanner = "Couldn't delete comment: \(board.lastError ?? "unknown error")"
        }
    }

    private func sendComment() async {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let doc = ADFBuilder.comment(from: text, mentions: pendingMentions)
        // Optimistic: insert immediately, revert on failure.
        let localID = "local-\(UUID().uuidString)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        let optimistic = JiraCommentPage.Comment(
            id: localID,
            author: .init(displayName: "You"),
            body: doc,
            created: formatter.string(from: Date())
        )
        comments.append(optimistic)
        let savedMentions = pendingMentions
        newComment = ""
        pendingMentions = [:]
        mentionFilter = nil
        let result = await board.addComment(issueKey: issue.key, doc)
        if result.accepted {
            statusBanner = nil
            // Swap the placeholder for the server-rendered comment (real id);
            // if the response didn't decode, keep the placeholder — the
            // server confirmed the post, so it must never be removed here.
            if let created = result.created,
               let index = comments.firstIndex(where: { $0.id == localID }) {
                comments[index] = created
            }
        } else {
            comments.removeAll { $0.id == localID }
            newComment = text
            pendingMentions = savedMentions
            statusBanner = "Couldn't post comment: \(board.lastError ?? "unknown error")"
        }
    }

    private func shortDate(_ iso: String) -> String {
        // Jira sends "2024-01-05T10:11:12.345+0000" (fractional, no colon
        // in the offset) — handle both shapes before giving up.
        let formats: [String] = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
            parser.dateFormat = fmt
            if let date = parser.date(from: iso) {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
        }
        return iso
    }
}

// MARK: - Flowing buttons for transitions

struct FlowButtons: View {
    let transitions: [JiraTransition]
    var action: (JiraTransition) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(transitions) { transition in
                Button(transition.name) {
                    action(transition)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Simple wrap layout for tags/buttons.
struct FlowLayout<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Lazy: just wrap in an HStack that scrolls horizontally.
        ScrollView([.horizontal], showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
        }
    }
}

// MARK: - ADF attributed rendering (mentions bold + link-blue)

extension ADFDocument {
    /// SwiftUI-renderable text; mention nodes come out bold and blue.
    var attributed: AttributedString {
        var out = AttributedString()
        for (i, para) in (content ?? []).enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += para.attributed
        }
        return out
    }
}

extension ADFNode {
    var attributed: AttributedString {
        if type == "mention" {
            var s = AttributedString(plainText)
            s.inlinePresentationIntent = .stronglyEmphasized
            s.foregroundColor = Color(nsColor: .linkColor)
            return s
        }
        if type == "hardBreak" { return AttributedString("\n") }
        if let text { return AttributedString(text) }
        if let content {
            return content.map(\.attributed).reduce(AttributedString(), +)
        }
        return AttributedString()
    }
}

// MARK: - ADF builder for comments with mentions

enum ADFBuilder {
    /// Build a comment document from text where "@DisplayName" occurrences
    /// listed in `mentions` become real ADF mention nodes.
    static func comment(from text: String, mentions: [String: String]) -> ADFDocument {
        var nodes: [ADFNode] = []
        var remaining = Substring(text)
        while let at = remaining.firstIndex(of: "@") {
            let before = remaining[..<at]
            if !before.isEmpty {
                nodes.append(ADFNode(type: "text", text: String(before)))
            }
            let after = remaining[remaining.index(after: at)...]
            if let name = mentions.keys
                .first(where: { name in
                    after.hasPrefix(name) && {
                        let tail = after.dropFirst(name.count)
                        return tail.isEmpty || tail.first!.isWhitespace || tail.first!.isNewline
                    }()
                }),
                let accountID = mentions[name] {
                nodes.append(ADFNode.mention(userID: accountID, displayName: name))
                remaining = after.dropFirst(name.count)
            } else {
                nodes.append(ADFNode(type: "text", text: "@"))
                remaining = after
            }
        }
        if !remaining.isEmpty {
            nodes.append(ADFNode(type: "text", text: String(remaining)))
        }
        return ADFDocument(content: [
            ADFNode(type: "paragraph", content: nodes.isEmpty ? [ADFNode(type: "text", text: text)] : nodes)
        ])
    }
}