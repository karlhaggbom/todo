import SwiftUI

// MARK: - GitHub activity view (everything impacting me across an account's repos)

struct GitHubActivityView: View {
    @EnvironmentObject var store: TodoStore

    let account: GitHubAccount
    let repos: [GitHubRepo]
    let token: String

    @StateObject private var holder: GitHubActivityModelHolder

    init(account: GitHubAccount, repos: [GitHubRepo], token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.repos = repos
        self.token = token
        _holder = StateObject(wrappedValue: GitHubActivityModelHolder(
            account: account, repos: repos, token: token, cache: cache
        ))
    }

    final class GitHubActivityModelHolder: ObservableObject {
        let model: GitHubActivityModel
        init(account: GitHubAccount, repos: [GitHubRepo], token: String, cache: BoardCaching?) {
            self.model = GitHubActivityModel(account: account, repos: repos, token: token, cache: cache)
        }
    }

    var body: some View {
        GitHubActivityContent(model: holder.model)
    }
}

private struct GitHubActivityContent: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel
    @ObservedObject var model: GitHubActivityModel

    /// Read activities stay hidden unless this is checked. Persists per account.
    @State private var showRead: Bool

    private var showReadScope: String { "github-activity-\(model.account.id)" }

    init(model: GitHubActivityModel) {
        self.model = model
        _showRead = State(initialValue: AppPreferences.showRead(scope: "github-activity-\(model.account.id)"))
    }

    private var visible: [GitHubActivityEntry] {
        showRead
            ? model.activity
            : model.activity.filter { !store.readIssueKeys.contains($0.readKey) }
    }

    /// Unread activities in the feed; 0 disables "Mark all as read".
    private var visibleUnreadCount: Int {
        model.activity.count { !store.readIssueKeys.contains($0.readKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text("Activity @\(model.account.login)")
                    .font(.system(size: 14, weight: .semibold))
                if let updated = model.lastUpdated {
                    Text("\(model.showingCached ? "cached" : "updated") \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(model.showingCached ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Toggle("Show read", isOn: $showRead)
                    .toggleStyle(.checkbox)
                Button {
                    store.markAllRead(model.activity.map(\.readKey))
                } label: {
                    Text("Mark all as read")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .pointingHandOnHover()
                .disabled(visibleUnreadCount == 0)
                .help("Mark every activity as read")
                Button {
                    Task { await model.load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .pointingHandOnHover()
            }
            .padding(14)

            Divider()

            if let error = model.lastError {
                ErrorBanner(message: error, onDismiss: { model.lastError = nil })
            } else if visible.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    model.activity.isEmpty ? "No activity" : "All read",
                    systemImage: model.activity.isEmpty ? "bell.slash" : "checkmark.seal",
                    description: Text(model.activity.isEmpty
                        ? "Nothing needs @\(model.account.login)'s attention."
                        : "You're all caught up — check “Show read” to see everything again.")
                )
                // Claim the remaining space so the VStack keeps the window
                // height and the header stays pinned to the top (otherwise
                // the shrunk stack centers in the window and the header
                // floats mid-screen).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { entry in
                    Button {
                        open(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ActivityReasonTag(reason: entry.reason, actor: entry.actor, at: entry.activityAt)
                            // Same card design as the Jira activity page;
                            // the repo label keeps cross-repo context.
                            GitHubCardView(issue: entry.issue, isSelected: false, repoName: entry.repo.name)
                        }
                        .padding(.vertical, 2)
                        .opacity(store.readIssueKeys.contains(entry.readKey) ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .pointingHandOnHover()
                    .contextMenu {
                        Button(store.readIssueKeys.contains(entry.readKey) ? "Mark as Unread" : "Mark as Read") {
                            if store.readIssueKeys.contains(entry.readKey) {
                                store.markIssueUnread(entry.readKey)
                            } else {
                                store.markIssueRead(entry.readKey)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { await model.load() }
        .onChange(of: showRead) { _, value in
            AppPreferences.setShowRead(value, scope: showReadScope)
        }
    }

    /// Open the detail sheet. The read key rides along: the issue becomes
    /// read only when the sheet closes (not on click, so the row stays
    /// visually fresh while browsing). An ephemeral board model supplies
    /// the detail view's client and optimistic-update hooks without
    /// touching any real board's state.
    private func open(_ entry: GitHubActivityEntry) {
        let board = GitHubBoardModel(account: model.account, repo: entry.repo, token: model.token)
        appModel.issueDetailTarget = IssueDetailTarget(
            content: .githubIssue(account: model.account, board: board, issue: entry.issue),
            readKey: entry.readKey,
            highlight: ActivityHighlight(reason: entry.reason, at: entry.activityAt, actor: entry.actor)
        )
    }
}

// MARK: - Add GitHub account sheet

struct AddGitHubAccountSheet: View {
    @EnvironmentObject var store: TodoStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = "https://api.github.com"
    @State private var token = ""
    @State private var owner = ""
    @State private var repoName = ""
    @State private var spaceName = ""
    @State private var verifying = false
    @State private var error: String?
    @State private var verifiedUser: GitHubUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add GitHub Account")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, verticalSpacing: 8) {
                labeledField("Display name", $name, placeholder: "Work")
                labeledField("API URL", $baseURL, placeholder: "https://api.github.com")
                labeledSecure("Personal access token", $token, placeholder: "classic PAT or fine-grained token")
            }

            Divider()
            Text("Initial Repo")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Owner").font(.system(size: 12)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("org-or-user", text: $owner).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Repo").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("repository", text: $repoName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Display name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("optional", text: $spaceName).textFieldStyle(.roundedBorder)
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let user = verifiedUser {
                Label("Verified as @\(user.login)", systemImage: "checkmark.circle.fill")
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
        .frame(width: 440)
        .buttonStyle(.bordered)
    }

    private var verifyDisabled: Bool {
        name.isEmpty || baseURL.isEmpty || token.isEmpty || owner.isEmpty || repoName.isEmpty || verifying
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
        let client = GitHubClient(credentials: .init(baseURL: baseURL, token: token))
        do {
            verifiedUser = try await client.myself()
        } catch {
            self.error = error.localizedDescription
        }
        verifying = false
    }

    private func save() {
        guard let user = verifiedUser else { return }
        do {
            let account = try store.addGitHubAccount(
                name: name.isEmpty ? user.login : name,
                baseURL: baseURL,
                login: user.login,
                token: token
            )
            _ = try store.addGitHubRepo(
                accountID: account.id,
                name: spaceName.isEmpty ? "\(owner)/\(repoName)" : spaceName,
                owner: owner,
                repo: repoName
            )
            dismiss()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Add repo sheet (for an existing account)

struct AddGitHubRepoSheet: View {
    @EnvironmentObject var store: TodoStore
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount

    @State private var owner = ""
    @State private var repoName = ""
    @State private var spaceName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Repo to \(account.name)")
                .font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Owner").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("org-or-user", text: $owner).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Repo").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("repository", text: $repoName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Display name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("optional", text: $spaceName).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    _ = try? store.addGitHubRepo(
                        accountID: account.id,
                        name: spaceName.isEmpty ? "\(owner)/\(repoName)" : spaceName,
                        owner: owner,
                        repo: repoName
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(owner.isEmpty || repoName.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}