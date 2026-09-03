import SwiftUI

// MARK: - GitHub mentions view (issues mentioning me across an account's repos)

struct GitHubMentionsView: View {
    @EnvironmentObject var store: TodoStore

    let account: GitHubAccount
    let repos: [GitHubRepo]
    let token: String

    @StateObject private var holder: GitHubMentionsModelHolder

    init(account: GitHubAccount, repos: [GitHubRepo], token: String) {
        self.account = account
        self.repos = repos
        self.token = token
        _holder = StateObject(wrappedValue: GitHubMentionsModelHolder(
            account: account, repos: repos, token: token
        ))
    }

    final class GitHubMentionsModelHolder: ObservableObject {
        let model: GitHubMentionsModel
        init(account: GitHubAccount, repos: [GitHubRepo], token: String) {
            self.model = GitHubMentionsModel(account: account, repos: repos, token: token)
        }
    }

    var body: some View {
        GitHubMentionsContent(model: holder.model)
    }
}

private struct GitHubMentionsContent: View {
    @ObservedObject var model: GitHubMentionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text("Mentions @\(model.account.login)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(14)

            Divider()

            if let error = model.lastError {
                ErrorBanner(message: error, onDismiss: { model.lastError = nil })
            } else if model.mentioned.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No mentions",
                    systemImage: "bell.slash",
                    description: Text("Nothing mentions @\(model.account.login).")
                )
            } else {
                List(model.mentioned) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(item.repo.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tint)
                            Text("#\(item.issue.number)")
                                .font(.system(size: 10, weight: .semibold).monospaced())
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        Text(item.issue.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.vertical, 2)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .task { await model.load() }
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