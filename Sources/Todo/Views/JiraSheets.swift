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
    @ObservedObject var model: MentionsModel
    let space: JiraSpace

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
                    description: Text("Nothing in \(space.projectKey) mentions you.")
                )
            } else {
                List(model.mentioned) { issue in
                    HStack(spacing: 8) {
                        JiraCardView(issue: issue, isSelected: false)
                            .padding(.vertical, 2)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .task { await model.load() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Space to \(account.name)")
                .font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Project key").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("TODO", text: $projectKey).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Space name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Team board", text: $spaceName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Custom JQL").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("optional", text: $jql).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    _ = try? store.addJiraSpace(
                        accountID: account.id,
                        name: spaceName.isEmpty ? projectKey : spaceName,
                        projectKey: projectKey,
                        jql: jql.isEmpty ? nil : jql
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectKey.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}