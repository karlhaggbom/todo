import SwiftUI

// MARK: - Jira board view (status lanes)

struct JiraBoardView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel

    let account: JiraAccount
    let space: JiraSpace

    @StateObject private var board: JiraBoardModelHolder

    init(account: JiraAccount, space: JiraSpace, token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.space = space
        _board = StateObject(wrappedValue: JiraBoardModelHolder(
            account: account, space: space, token: token, cache: cache
        ))
    }

    final class JiraBoardModelHolder: ObservableObject {
        let model: JiraBoardModel
        init(account: JiraAccount, space: JiraSpace, token: String, cache: BoardCaching? = nil) {
            self.model = JiraBoardModel(account: account, space: space, token: token, cache: cache)
        }
    }

    var body: some View {
        JiraBoardContent(
            model: board.model,
            account: account,
            space: space,
            appModel: appModel
        )
    }
}

private struct JiraBoardContent: View {
    @ObservedObject var model: JiraBoardModel
    let account: JiraAccount
    let space: JiraSpace
    @ObservedObject var appModel: AppModel

    var body: some View {
        let _ = {
            Diag.boardBodyEvals += 1
            if Diag.boardBodyEvals % 10 == 1 {
                Diag.log.info("board body #\(Diag.boardBodyEvals) statuses=\(model.statuses.count) issues=\(model.issues.count) loading=\(model.isLoading) err=\(model.lastError != nil)")
            }
        }()
        VStack(spacing: 0) {
            header
            if let error = model.lastError {
                errorBanner(error)
            }
            boardBody
        }
        .task { await model.load() }
        .onAppear {
            Diag.log.info("JiraBoardContent appeared project=\(space.projectKey, privacy: .public)")
            model.filterText = appModel.filterText
            appModel.navigable = { [weak nav = model] in nav }
            appModel.resolveDetail = { target in
                issueAt(target).map {
                    DetailSheetContent.jiraTicket(account: account, board: model, issue: $0)
                }
            }
            appModel.createIssueHandler = { [weak model] in
                if let model {
                    appModel.createTarget = CreateIssueTarget(content: .jiraIssue(account: account, board: model))
                }
            }
        }
        .onDisappear {
            appModel.createIssueHandler = nil
        }
        .onChange(of: appModel.filterText) { model.filterText = $0 }
    }

    /// Resolve the double-clicked issue from the visible board.
    private func issueAt(_ target: CursorPosition) -> JiraIssue? {
        guard model.statuses.indices.contains(target.lane) else { return nil }
        let status = model.statuses[target.lane]
        let issues = model.issues(inStatus: status.name)
        return issues.indices.contains(target.item) ? issues[target.item] : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(space.name)")
                .font(.system(size: 14, weight: .semibold))
            Text(space.projectKey)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            if let updated = model.lastUpdated {
                Text("\(model.showingCached ? "cached" : "updated") \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(model.showingCached ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                appModel.createTarget = CreateIssueTarget(content: .jiraIssue(account: account, board: model))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("New issue (n)")
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        ErrorBanner(message: message, onDismiss: { model.lastError = nil })
    }

    private var boardBody: some View {
        Group {
            if model.statuses.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No statuses",
                    systemImage: "square.split.3x1",
                    description: Text("Could not load board configuration for \(space.projectKey).")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal]) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(model.statuses.enumerated()), id: \.element.id) { laneIndex, status in
                                jiraLane(status: status, laneIndex: laneIndex)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(14)
                    }
                    .onChange(of: appModel.selectedLane) { _, _ in
                        guard model.statuses.indices.contains(appModel.selectedLane) else { return }
                        proxy.scrollTo(model.statuses[appModel.selectedLane].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func jiraLane(status: JiraStatus, laneIndex: Int) -> some View {
        let issues = model.issues(inStatus: status.name)
        let isSelected = appModel.selectedLane == laneIndex
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 7, height: 7)
                Text(status.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(issues.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            // Cards scroll vertically within the lane. This bounds the lane's
            // ideal height to the viewport; without it a tall lane (100+
            // issues) makes the whole board content taller than the window
            // and the split view lays the UI out above the visible area.
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            JiraCardView(issue: issue, isSelected: isSelected && appModel.selectedItem == index)
                                .modifier(InstantTap(
                                    single: {
                                        appModel.selectedLane = laneIndex
                                        appModel.selectedItem = index
                                    },
                                    double: {
                                        appModel.detailTarget = CursorPosition(lane: laneIndex, item: index)
                                    }
                                ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: appModel.selectedItem) { _, _ in
                    guard appModel.selectedLane == laneIndex,
                          issues.indices.contains(appModel.selectedItem) else { return }
                    proxy.scrollTo(issues[appModel.selectedItem].id, anchor: .center)
                }
            }
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: isSelected ? 1.5 : 1)
        )
    }

    private func color(for status: JiraStatus) -> Color {
        switch status.categoryKey {
        case "new": return .blue
        case "indeterminate": return .orange
        case "done": return .green
        default: return .gray
        }
    }
}

// MARK: - Jira card

struct JiraCardView: View {
    let issue: JiraIssue
    var isSelected: Bool

    private var symbol: String {
        switch issue.fields.issuetype.name.lowercased() {
        case let n where n.contains("bug"): return "ladybug"
        case let n where n.contains("epic"): return "trophy"
        case let n where n.contains("story"): return "bookmark"
        case let n where n.contains("task"): return "square"
        default: return "circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(issue.key)
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(issue.fields.summary)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .cardHover()
    }
}