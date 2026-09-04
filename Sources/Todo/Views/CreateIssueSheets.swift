import SwiftUI

// MARK: - Create issue (Jira)

/// New-issue sheet for Jira boards: title, description, assignee, priority,
/// and sprint — the sprint picker is pre-selected to the currently active
/// sprint when one is running. Fields arrive from the metadata fetch; the
/// sheet is fully usable while that is in flight (title/body first).
struct CreateIssueSheet: View {
    @Environment(\.dismiss) private var dismiss

    let account: JiraAccount
    @ObservedObject var board: JiraBoardModel
    /// Non-nil = edit mode: the same form, prefilled, with a Save button
    /// instead of Create (the create modal doubles as the edit modal).
    var editing: JiraIssue? = nil

    @State private var title = ""
    @State private var bodyText = ""
    @State private var users: [JiraUser] = []
    @State private var assigneeID: String?
    @State private var priorities: [JiraClient.JiraPriority] = []
    @State private var priorityID: String?
    @State private var useSprint = false
    @State private var boards: [JiraClient.JiraBoardsPage.Board] = []
    @State private var sprintsByBoard: [Int: JiraClient.JiraSprintsPage.Sprint?] = [:]
    @State private var selectedBoardID: Int?
    @State private var resolvedProjectKey: String?
    @State private var loadingMeta = false
    @State private var errorBanner: String?
    @State private var isCreating = false
    /// Edit mode: whether the issue is in the selected board's active
    /// sprint right now (server truth), so Save can diff the toggle.
    @State private var inSelectedSprint = false
    /// Edit mode: false when the issue's current priority isn't among the
    /// server's priorities — then the field is left untouched on save.
    @State private var priorityMatched = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.map { "Edit \($0.key)" } ?? "New Issue in \(resolvedProjectKey ?? board.space.projectKey)")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Title").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Issue summary", text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Description").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                GridRow {
                    Text("Assignee").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Assignee", selection: $assigneeID) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(users) { user in
                            Text(user.displayName).tag(String?.some(user.accountID))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Priority").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Priority", selection: $priorityID) {
                        if priorities.isEmpty {
                            Text("Default").tag(String?.none)
                        }
                        ForEach(priorities) { priority in
                            Text(priority.name).tag(String?.some(priority.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Board").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if loadingMeta && boards.isEmpty {
                            ProgressView().controlSize(.mini)
                        }
                        Picker("Board", selection: $selectedBoardID) {
                            ForEach(boards, id: \.id) { b in
                                Text(b.name).tag(Int?.some(b.id))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedBoardID) { _, _ in
                            if editing != nil {
                                // Membership is server truth: reflect whether
                                // the issue is in this board's active sprint.
                                Task { await syncSprintMembership() }
                            } else {
                                useSprint = selectedSprint != nil
                            }
                        }
                    }
                }
                GridRow {
                    Text("Sprint").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Toggle("", isOn: $useSprint)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(selectedSprint == nil)
                        if let selectedSprint {
                            Text(selectedSprint.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else if loadingMeta {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("No active sprint")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if let errorBanner {
                Text(errorBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                if loadingMeta {
                    Text("Loading priorities, users and sprint…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editing == nil ? "Create" : "Save") {
                    if editing == nil {
                        Task { await create() }
                    } else {
                        Task { await edit() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { prefillIfEditing(); await loadMeta() }
    }

    private var selectedSprint: JiraClient.JiraSprintsPage.Sprint? {
        guard let id = selectedBoardID, let s = sprintsByBoard[id] else { return nil }
        return s
    }

    /// Seed the form from the issue being edited, before any metadata has
    /// arrived, so the sheet is instantly populated.
    private func prefillIfEditing() {
        guard let editing else { return }
        title = editing.fields.summary
        bodyText = editing.fields.description?.plainText ?? ""
        assigneeID = editing.fields.assignee?.accountID
    }

    /// Edit mode: sync the sprint toggle with the issue's actual membership
    /// in the selected board's active sprint.
    private func syncSprintMembership() async {
        guard let editing, let sprint = selectedSprint else {
            inSelectedSprint = false
            useSprint = false
            return
        }
        let member = await board.client.issueInSprint(issueKey: editing.key, sprintID: sprint.id)
        inSelectedSprint = member
        useSprint = member
    }

    private func loadMeta() async {
        loadingMeta = true
        do {
            // Custom-JQL boards (e.g. `sprint in openSprints()`) may carry a
            // stored project key that Jira rejects — resolve the real
            // project from the board's own issues and use it throughout.
            let key = try await board.client.boardProjectKey(jql: board.jql)
                ?? board.space.projectKey
            resolvedProjectKey = key
            Diag.log.info("create-issue resolved project=\(key, privacy: .public)")
            // Fetch priorities, assignable users and the boards in
            // parallel; failures degrade to defaults rather than blocking.
            async let prioritiesTask = board.client.priorities()
            async let usersTask = board.client.assignableUsers(projectKey: key)
            async let boardsTask = board.client.boards(projectKey: key)
            let (p, u, b) = try await (prioritiesTask, usersTask, boardsTask)
            priorities = p
            users = u
            boards = b
            // Probe every board for an active sprint (Kanban boards simply
            // report none). Done concurrently — it's one request per board.
            var byBoard: [Int: JiraClient.JiraSprintsPage.Sprint?] = [:]
            try await withThrowingTaskGroup(of: (Int, JiraClient.JiraSprintsPage.Sprint?).self) { group in
                for b in b {
                    group.addTask {
                        (b.id, try await self.board.client.activeSprint(boardID: b.id))
                    }
                }
                for try await (id, s) in group { byBoard[id] = s }
            }
            sprintsByBoard = byBoard
            // Pre-select the board pinned to the space — issues created here
            // land on it (and its sprint via the onChange below); fall back
            // to the first board with a running sprint, else the first.
            let pinned = board.space.boardID
            selectedBoardID = b.first(where: { $0.id == pinned })?.id
                ?? b.first(where: { byBoard[$0.id] != nil })?.id
                ?? b.first?.id
            if let editing {
                // Edit mode: mirror the issue's current values onto the form.
                // The sprint toggle is synced by onChange via a membership
                // check; only defaults belong here.
                if let name = editing.fields.priority?.name,
                   let match = p.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    priorityID = match.id
                    priorityMatched = true
                } else if editing.fields.priority != nil {
                    priorityMatched = false
                }
                if let acc = editing.fields.assignee?.accountID,
                   !u.contains(where: { $0.accountID == acc }) {
                    users.append(JiraUser(accountID: acc, displayName: editing.fields.assignee?.displayName ?? "Unknown", avatarURL: nil))
                }
            } else {
                useSprint = selectedSprint != nil
                priorityID = p.first { $0.name.lowercased() == "medium" }?.id ?? p.first?.id
            }
        } catch {
            Diag.log.error("create-issue meta failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't load metadata (assignee/priority/sprint): \(error.localizedDescription)"
        }
        loadingMeta = false
    }

    private func create() async {
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        let fields = JiraClient.JiraCreateFields(
            project: ["key": resolvedProjectKey ?? board.space.projectKey],
            summary: summary,
            issuetype: ["name": "Task"],
            description: ADFDocument.paragraphs(from: bodyText),
            assignee: assigneeID.map { ["accountId": $0] },
            priority: priorityID.map { ["id": $0] }
        )
        do {
            let created = try await board.client.createIssue(fields: fields)
            // Sprint membership can't be set at creation time in the REST
            // API — move the new issue into the selected board's active
            // sprint separately. Failure here shouldn't fail the (successful)
            // creation.
            if useSprint, let selectedSprint {
                do {
                    try await board.client.addIssueToSprint(sprintID: selectedSprint.id, issueKey: created.key)
                } catch {
                    Diag.log.error("add-to-sprint failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Fetch the full issue and put it on the board immediately.
            let resp = try await board.client.issue(key: created.key)
            board.insertCreated(JiraIssue(key: resp.key, fields: resp.fields))
            dismiss()
        } catch {
            Diag.log.error("jira create-issue failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't create issue: \(error.localizedDescription)"
        }
    }

    /// Edit mode: PUT the changed fields, mirror sprint membership changes,
    /// then patch the board copy in place (no reload needed).
    private func edit() async {
        guard let editing else { return }
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        let description = ADFDocument.paragraphs(from: bodyText)
        // Double optionals: nil = don't touch the field, .some(nil) = clear it.
        let priority: [String: String]??
        if let priorityID {
            priority = .some(["id": priorityID])
        } else if !priorityMatched {
            // Current priority isn't representable in this form — leave it.
            priority = nil
        } else if editing.fields.priority != nil {
            priority = .some(nil)
        } else {
            priority = nil
        }
        let assignee: [String: String]??
        if let assigneeID {
            assignee = .some(["accountId": assigneeID])
        } else if editing.fields.assignee != nil {
            assignee = .some(nil)
        } else {
            assignee = nil
        }
        do {
            try await board.client.editIssue(key: editing.key, fields: .init(
                summary: summary,
                description: description,
                priority: priority,
                assignee: assignee
            ))
            // Sprint membership is managed outside the issue — diff the
            // toggle against server truth. Failure here shouldn't fail the
            // (successful) field edit.
            if let selectedSprint {
                do {
                    if useSprint && !inSelectedSprint {
                        try await board.client.addIssueToSprint(sprintID: selectedSprint.id, issueKey: editing.key)
                    } else if !useSprint && inSelectedSprint {
                        try await board.client.removeIssueFromSprint(sprintID: selectedSprint.id, issueKey: editing.key)
                    }
                } catch {
                    Diag.log.error("sprint-membership edit failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            board.applyEdit(
                issueKey: editing.key,
                summary: summary,
                description: description,
                assignee: assigneeID.map { id in
                    JiraIssue.Fields.Assignee(
                        displayName: users.first(where: { $0.accountID == id })?.displayName,
                        accountID: id
                    )
                },
                priority: priorityID.flatMap { id in
                    priorities.first(where: { $0.id == id }).map { JiraIssue.Fields.Priority(name: $0.name) }
                }
            )
            dismiss()
        } catch {
            Diag.log.error("jira edit-issue failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create issue (GitHub)

/// New-issue sheet for GitHub boards: title, description, assignee (a repo
/// collaborator). On success the created issue appears on the Open lane.
struct CreateGitHubIssueSheet: View {
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    @ObservedObject var board: GitHubBoardModel
    /// Non-nil = edit mode: prefilled form, Save instead of Create.
    var editing: GitHubIssue? = nil

    @State private var title = ""
    @State private var bodyText = ""
    @State private var users: [GitHubUser] = []
    @State private var assigneeLogin: String?
    @State private var loadingUsers = false
    @State private var errorBanner: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.map { "Edit #\($0.number)" } ?? "New Issue in \(board.repo.owner)/\(board.repo.repo)")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Title").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Issue title", text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Description").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                GridRow {
                    Text("Assignee").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if loadingUsers {
                            ProgressView().controlSize(.mini)
                        }
                        Picker("Assignee", selection: $assigneeLogin) {
                            Text("Unassigned").tag(String?.none)
                            ForEach(users) { user in
                                Text("@\(user.login)").tag(String?.some(user.login))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            if let errorBanner {
                Text(errorBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editing == nil ? "Create" : "Save") {
                    if editing == nil {
                        Task { await create() }
                    } else {
                        Task { await edit() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            prefillIfEditing()
            await loadUsers()
        }
    }

    /// Seed the form from the issue being edited before collaborators load.
    private func prefillIfEditing() {
        guard let editing else { return }
        title = editing.title
        bodyText = editing.body ?? ""
        assigneeLogin = editing.assignees?.first?.login
    }

    private func loadUsers() async {
        loadingUsers = true
        do {
            users = try await board.client.collaborators(owner: board.repo.owner, repo: board.repo.repo)
            // Edit mode: make sure the issue's current assignees are
            // pickable even if they're outside the collaborator list.
            if let editing {
                for a in editing.assignees ?? [] where !users.contains(where: { $0.login == a.login }) {
                    users.append(GitHubUser(login: a.login, name: a.name))
                }
            }
        } catch {
            Diag.log.error("create-issue collaborators failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't load collaborators: \(error.localizedDescription)"
        }
        loadingUsers = false
    }

    private func create() async {
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await board.client.createIssue(
                owner: board.repo.owner,
                repo: board.repo.repo,
                title: summary,
                body: bodyText.isEmpty ? nil : bodyText,
                assignees: assigneeLogin.map { [$0] } ?? []
            )
            board.insertCreated(created)
            dismiss()
        } catch {
            Diag.log.error("github create-issue failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't create issue: \(error.localizedDescription)"
        }
    }

    /// Edit mode: PATCH title/body/assignees. The PATCH replaces the whole
    /// assignee list, so a multi-assignee issue keeps its full list when the
    /// (single) picker was left on the first assignee. The server response
    /// replaces the board copy.
    private func edit() async {
        guard let editing else { return }
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        var assignees: [String] = assigneeLogin.map { [$0] } ?? []
        let original = (editing.assignees ?? []).map(\.login)
        if assignees == Array(original.prefix(1)) {
            assignees = original
        }
        do {
            let updated = try await board.client.editIssue(
                owner: board.repo.owner,
                repo: board.repo.repo,
                number: editing.number,
                title: summary,
                body: bodyText.isEmpty ? nil : bodyText,
                assignees: assignees
            )
            board.applyEdit(updated)
            dismiss()
        } catch {
            Diag.log.error("github edit-issue failed: \(error.localizedDescription, privacy: .public)")
            errorBanner = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
// MARK: - Delete confirmation

/// Small confirmation sheet for `d d` and context-menu deletes. Jira
/// deletions are permanent — one explicit confirm, then it's gone. Enter
/// confirms, Esc cancels.
struct ConfirmDeleteSheet: View {
    @EnvironmentObject var store: TodoStore
    @Environment(\.dismiss) private var dismiss

    let target: DeleteTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.system(size: 15, weight: .semibold))
            Text(subline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    perform()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var heading: String {
        switch target.content {
        case .localTask(let task): return "Delete “\(task.title)”?"
        case .jiraIssue(_, _, let issue): return "Delete \(issue.key)?"
        }
    }

    private var subline: String {
        switch target.content {
        case .localTask:
            return "The task will be removed from the board. This can’t be undone."
        case .jiraIssue(_, _, let issue):
            return "“\(issue.fields.summary)” will be permanently deleted from Jira. This can’t be undone."
        }
    }

    private func perform() {
        switch target.content {
        case .localTask(let task):
            try? store.deleteTask(task.id)
        case .jiraIssue(_, let board, let issue):
            Task { await board.deleteIssue(issueKey: issue.key) }
        }
        dismiss()
    }
}
