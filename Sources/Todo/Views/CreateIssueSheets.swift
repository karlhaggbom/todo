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
    @State private var sprint: JiraClient.JiraSprintsPage.Sprint?
    @State private var useSprint = false
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
                    Text("Sprint").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Toggle("", isOn: $useSprint)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(sprint == nil)
                        if let sprint {
                            Text(sprint.name)
                                .font(.system(size: 12))
                                .foregroundStyle(sprint == nil ? .tertiary : .secondary)
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
            // Fetch priorities, assignable users and the active sprint in
            // parallel; failures degrade to defaults rather than blocking.
            async let prioritiesTask = board.client.priorities()
            async let usersTask = board.client.assignableUsers(projectKey: key)
            async let sprintTask = board.client.activeSprint(projectKey: key)
            let (p, u, s) = try await (prioritiesTask, usersTask, sprintTask)
            priorities = p
            users = u
            sprint = s
            useSprint = s != nil
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
            // API — move the new issue into the active sprint separately.
            // Failure here shouldn't fail the (successful) creation.
            if useSprint, let sprint {
                do {
                    try await board.client.addIssueToSprint(sprintID: sprint.id, issueKey: created.key)
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