import SwiftUI

// MARK: - Mentions view (issues mentioning me in one project)

struct MentionsView: View {
    @EnvironmentObject var store: TodoStore

    let account: JiraAccount
    let space: JiraSpace
    let token: String

    @StateObject private var holder: MentionsModelHolder

    init(account: JiraAccount, space: JiraSpace, token: String) {
        self.account = account
        self.space = space
        self.token = token
        _holder = StateObject(wrappedValue: MentionsModelHolder(
            account: account, space: space, token: token
        ))
    }

    final class MentionsModelHolder: ObservableObject {
        let model: MentionsModel
        init(account: JiraAccount, space: JiraSpace, token: String) {
            self.model = MentionsModel(account: account, space: space, token: token)
        }
    }

    var body: some View {
        MentionsContent(model: holder.model, space: space)
    }
}

private struct MentionsContent: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel
    @ObservedObject var model: MentionsModel
    let space: JiraSpace

    /// Read tickets stay hidden unless this is checked (default off).
    @State private var showRead = false

    private var visible: [JiraIssue] {
        showRead
            ? model.mentioned
            : model.mentioned.filter { !store.readIssueKeys.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text("Mentions in \(space.name)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Toggle("Show read", isOn: $showRead)
                    .toggleStyle(.checkbox)
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .pointingHandOnHover()
            }
            .padding(14)

            Divider()

            if let error = model.lastError {
                ErrorBanner(message: error, onDismiss: { model.lastError = nil })
            } else if visible.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    model.mentioned.isEmpty ? "No mentions" : "All read",
                    systemImage: model.mentioned.isEmpty ? "bell.slash" : "checkmark.seal",
                    description: Text(model.mentioned.isEmpty
                        ? "Nothing in \(space.projectKey) mentions you."
                        : "You've read every mention — check “Show read” to see them again.")
                )
            } else {
                List(visible) { issue in
                    Button {
                        open(issue)
                    } label: {
                        JiraCardView(issue: issue, isSelected: false)
                            .padding(.vertical, 2)
                            .opacity(store.readIssueKeys.contains(issue.key) ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .pointingHandOnHover()
                }
                .listStyle(.plain)
            }
        }
        .task { await model.load() }
    }

    /// Mark the issue read and open its detail sheet. An ephemeral board
    /// model supplies the detail view's client and optimistic-update hooks
    /// without touching any real board's state.
    private func open(_ issue: JiraIssue) {
        store.markIssueRead(issue.key)
        let board = JiraBoardModel(account: model.account, space: space, token: model.token)
        appModel.issueDetailTarget = IssueDetailTarget(content: .jiraTicket(
            account: model.account, board: board, issue: issue
        ))
    }
}

// MARK: - Add Jira account sheet

struct AddAccountSheet: View {
    @EnvironmentObject var store: TodoStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var baseURL = ""
    @State private var apiToken = ""
    @State private var jql = ""
    @State private var projectKey = ""
    @State private var spaceName = ""
    @State private var verifying = false
    @State private var error: String?
    @State private var verifiedUser: JiraUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Jira Account")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, verticalSpacing: 8) {
                labeledField("Display name", $name, placeholder: "Work")
                labeledField("Email", $email, placeholder: "you@company.com")
                labeledField("Site URL", $baseURL, placeholder: "https://yourorg.atlassian.net")
                labeledSecure("API token", $apiToken, placeholder: "create at id.atlassian.com")
            }

            Divider()
            Text("Initial Space (project)")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, verticalSpacing: 8) {
                labeledField("Project key", $projectKey, placeholder: "TODO")
                labeledField("Space name", $spaceName, placeholder: "Team board")
                labeledField("Custom JQL (optional)", $jql, placeholder: "project = TODO AND sprint in openSprints()")
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let user = verifiedUser {
                Label("Verified as \(user.displayName)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if verifiedUser == nil {
                    Button("Verify & Save") { Task { await verifyAndSave() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(verifyDisabled)
                } else {
                    Button("Save Account") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .buttonStyle(.bordered)
    }

    private var verifyDisabled: Bool {
        name.isEmpty || email.isEmpty || baseURL.isEmpty || apiToken.isEmpty
            || projectKey.isEmpty || verifying
    }

    private func labeledField(_ label: String, _ field: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField(placeholder, text: field)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledSecure(_ label: String, _ field: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            SecureField(placeholder, text: field)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func verifyAndSave() async {
        verifying = true
        error = nil
        let client = JiraClient(credentials: .init(
            baseURL: baseURL, email: email, apiToken: apiToken
        ))
        do {
            let user = try await client.myself()
            verifiedUser = user
        } catch {
            self.error = error.localizedDescription
        }
        verifying = false
    }

    private func save() {
        guard let user = verifiedUser else { return }
        do {
            let account = try store.addJiraAccount(
                name: name.isEmpty ? user.displayName : name,
                email: email,
                baseURL: baseURL,
                apiToken: apiToken
            )
            _ = try store.addJiraSpace(
                accountID: account.id,
                name: spaceName.isEmpty ? projectKey : spaceName,
                projectKey: projectKey,
                jql: jql.isEmpty ? nil : jql
            )
            dismiss()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Add space sheet (for an existing account)

struct AddSpaceSheet: View {
    @EnvironmentObject var store: TodoStore
    @Environment(\.dismiss) private var dismiss

    let account: JiraAccount

    @State private var projectKey = ""
    @State private var spaceName = ""
    @State private var jql = ""
    @State private var boards: [JiraClient.JiraBoardsPage.Board]?
    @State private var selectedBoardID: Int?
    @State private var resolvedKey: String?
    @State private var loadingBoards = false
    @State private var errorBanner: String?

    /// The project key that actually owns the issues — resolved from the
    /// project's own issues when possible, else what the user typed.
    private var key: String { resolvedKey ?? projectKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Space to \(account.name)")
                .font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Project key").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("TODO", text: $projectKey).textFieldStyle(.roundedBorder)
                        .disabled(boards != nil)
                }
                GridRow {
                    Text("Space name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Team board", text: $spaceName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Custom JQL").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("optional", text: $jql).textFieldStyle(.roundedBorder)
                }
                if let boards {
                    GridRow {
                        Text("Board").font(.system(size: 12)).foregroundStyle(.secondary)
                        if boards.isEmpty {
                            Text("No boards found — a space needs a board so new issues land on it")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        } else {
                            Picker("Board", selection: $selectedBoardID) {
                                ForEach(boards, id: \.id) { b in
                                    Text(b.name).tag(Int?.some(b.id))
                                }
                            }
                            .labelsHidden()
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
                Spacer()
                Button("Cancel") { dismiss() }
                if boards == nil {
                    Button("Find Boards") { Task { await findBoards() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(projectKey.trimmingCharacters(in: .whitespaces).isEmpty || loadingBoards)
                    if loadingBoards {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button("Add") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedBoardID == nil)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    /// Two-phase add: first resolve the project (and its real key) and list
    /// its agile boards; the space is then saved with one of them pinned, so
    /// issues created from the space default to that board and its sprint.
    private func findBoards() async {
        loadingBoards = true
        errorBanner = nil
        let typed = projectKey.trimmingCharacters(in: .whitespaces)
        guard let token = try? KeychainStore.token(forAccountID: account.id), !token.isEmpty else {
            errorBanner = "Missing API token for \(account.name) in Keychain"
            loadingBoards = false
            return
        }
        let client = JiraClient(credentials: .init(
            baseURL: account.baseURL, email: account.email, apiToken: token
        ))
        do {
            async let boardsTask = client.boards(projectKey: typed)
            // A stale or aliased key still lists boards via agile, but the
            // search API tells us the key the issues actually carry.
            async let resolvedTask = try? client.boardProjectKey(
                jql: "project = \"\(typed)\" ORDER BY updated DESC")
            let (found, resolved) = try await (boardsTask, resolvedTask)
            resolvedKey = resolved ?? typed
            boards = found
            selectedBoardID = found.count == 1 ? found[0].id : nil
            Diag.log.info("add-space boards=\(found.count) resolvedKey=\(resolved ?? "nil", privacy: .public)")
            if found.isEmpty {
                errorBanner = "No boards found for project \(resolvedKey ?? typed)"
            }
        } catch {
            errorBanner = "Couldn't load boards: \(error.localizedDescription)"
        }
        loadingBoards = false
    }

    private func save() {
        guard let boardID = selectedBoardID else { return }
        _ = try? store.addJiraSpace(
            accountID: account.id,
            name: spaceName.isEmpty ? key : spaceName,
            projectKey: key,
            jql: jql.isEmpty ? nil : jql,
            boardID: boardID
        )
        dismiss()
    }
}