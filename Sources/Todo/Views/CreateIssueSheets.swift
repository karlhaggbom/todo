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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue in \(resolvedProjectKey ?? board.space.projectKey)")
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
                            useSprint = selectedSprint != nil
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
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await loadMeta() }
    }

    private var selectedSprint: JiraClient.JiraSprintsPage.Sprint? {
        guard let id = selectedBoardID, let s = sprintsByBoard[id] else { return nil }
        return s
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
            useSprint = selectedSprint != nil
            priorityID = p.first { $0.name.lowercased() == "medium" }?.id ?? p.first?.id
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
}

// MARK: - Create issue (GitHub)

/// New-issue sheet for GitHub boards: title, description, assignee (a repo
/// collaborator). On success the created issue appears on the Open lane.
struct CreateGitHubIssueSheet: View {
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    @ObservedObject var board: GitHubBoardModel

    @State private var title = ""
    @State private var bodyText = ""
    @State private var users: [GitHubUser] = []
    @State private var assigneeLogin: String?
    @State private var loadingUsers = false
    @State private var errorBanner: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue in \(board.repo.owner)/\(board.repo.repo)")
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
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await loadUsers() }
    }

    private func loadUsers() async {
        loadingUsers = true
        do {
            users = try await board.client.collaborators(owner: board.repo.owner, repo: board.repo.repo)
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
