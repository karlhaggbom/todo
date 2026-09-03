import SwiftUI

// MARK: - GitHub board view (lifecycle lanes)

struct GitHubBoardView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var appModel: AppModel

    let account: GitHubAccount
    let repo: GitHubRepo

    @StateObject private var board: GitHubBoardModelHolder

    init(account: GitHubAccount, repo: GitHubRepo, token: String, cache: BoardCaching? = nil) {
        self.account = account
        self.repo = repo
        _board = StateObject(wrappedValue: GitHubBoardModelHolder(
            account: account, repo: repo, token: token, cache: cache
        ))
    }

    final class GitHubBoardModelHolder: ObservableObject {
        let model: GitHubBoardModel
        init(account: GitHubAccount, repo: GitHubRepo, token: String, cache: BoardCaching? = nil) {
            self.model = GitHubBoardModel(account: account, repo: repo, token: token, cache: cache)
        }
    }

    var body: some View {
        GitHubBoardContent(
            model: board.model,
            account: account,
            repo: repo,
            appModel: appModel
        )
    }
}

private struct GitHubBoardContent: View {
    @ObservedObject var model: GitHubBoardModel
    let account: GitHubAccount
    let repo: GitHubRepo
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.lastError {
                ErrorBanner(message: error, onDismiss: { model.lastError = nil })
            }
            boardBody
        }
        .task { await model.load() }
        .onAppear {
            model.filterText = appModel.filterText
            appModel.navigable = { [weak nav = model] in nav }
            appModel.resolveDetail = { target in
                issueAt(target).map {
                    DetailSheetContent.githubIssue(account: account, board: model, issue: $0)
                }
            }
        }
        .onChange(of: appModel.filterText) { model.filterText = $0 }
    }

    /// Resolve the double-clicked issue from the visible board.
    private func issueAt(_ target: CursorPosition) -> GitHubIssue? {
        guard model.lanes.indices.contains(target.lane) else { return nil }
        let lane = model.lanes[target.lane]
        let issues = model.issues(inLane: lane.id)
        return issues.indices.contains(target.item) ? issues[target.item] : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(repo.name)
                .font(.system(size: 14, weight: .semibold))
            Text("\(repo.owner)/\(repo.repo)")
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

    private var boardBody: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal]) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(model.lanes.enumerated()), id: \.element.id) { laneIndex, lane in
                        laneView(lane: lane, laneIndex: laneIndex)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(14)
            }
            .onChange(of: appModel.selectedLane) { _, _ in
                guard model.lanes.indices.contains(appModel.selectedLane) else { return }
                proxy.scrollTo(model.lanes[appModel.selectedLane].id, anchor: .center)
            }
        }
    }

    private func laneView(lane: GitHubLane, laneIndex: Int) -> some View {
        let issues = model.issues(inLane: lane.id)
        let isSelected = appModel.selectedLane == laneIndex
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: lane))
                    .frame(width: 7, height: 7)
                Text(lane.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(issues.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            // Cards scroll vertically within the lane so a tall lane can't
            // inflate the board's ideal height (see the Jira board fix).
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            GitHubCardView(issue: issue, isSelected: isSelected && appModel.selectedItem == index)
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

    private func color(for lane: GitHubLane) -> Color {
        switch lane.id {
        case GitHubLane.open.id: return .blue
        case GitHubLane.completed.id: return .green
        case GitHubLane.notPlanned.id: return .gray
        default: return .gray
        }
    }
}

// MARK: - GitHub card

struct GitHubCardView: View {
    let issue: GitHubIssue
    var isSelected: Bool

    private var symbol: String {
        switch issue.state {
        case "open": return "circlebadge"
        default: return issue.stateReason == "not_planned" ? "xmark.circle" : "checkmark.circle"
        }
    }

    private var stateColor: Color {
        issue.state == "open" ? Color(nsColor: .systemGreen) : Color.secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
                Text("#\(issue.number)")
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                if !issue.labels.isEmpty {
                    Text(labelSummary)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .separatorColor).opacity(0.3)))
                        .lineLimit(1)
                }
            }
            Text(issue.title)
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

    private var labelSummary: String {
        issue.labels.map(\.name).prefix(2).joined(separator: " · ")
    }
}