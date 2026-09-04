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

    // Drag-and-drop (same machinery as the local board): frames are
    // reported in the "board" coordinate space for hit-testing.
    @State private var laneFrames: [String: CGRect] = [:]
    @State private var cardFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.lastError {
                ErrorBanner(message: error, onDismiss: { model.lastError = nil })
            }
            ZStack(alignment: .topLeading) {
                boardBody
                floatingCard
            }
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
            appModel.registerCreateIssueHandler(owner: model) {
                appModel.createTarget = CreateIssueTarget(content: .githubIssue(account: account, board: model))
            }
            Diag.log.info("github create handler registered repo=\(repo.repo, privacy: .public)")
        }
        .onDisappear {
            appModel.clearCreateIssueHandler(owner: model)
            Diag.log.info("github create handler cleared")
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
            Toggle("My tickets only", isOn: $model.mineOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Only show issues assigned to you")
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                appModel.createTarget = CreateIssueTarget(content: .githubIssue(account: account, board: model))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("New issue (n)")
            .pointingHandOnHover()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .pointingHandOnHover()
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
            .coordinateSpace(name: "board")
            .onPreferenceChange(LaneFramesKey.self) { laneFrames = $0 }
            .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
            .onChange(of: appModel.selectedLane) { _, _ in
                guard model.lanes.indices.contains(appModel.selectedLane) else { return }
                proxy.scrollTo(model.lanes[appModel.selectedLane].id, anchor: .center)
            }
        }
    }

    private func laneView(lane: GitHubLane, laneIndex: Int) -> some View {
        let issues = model.issues(inLane: lane.id)
        let isSelected = appModel.selectedLane == laneIndex
        let isDropTarget = appModel.drag?.settling == false
            && appModel.drag?.insertion?.lane == laneIndex
        let placeholderIndex = insertionIndex(laneIndex: laneIndex)
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
                            if placeholderIndex == index {
                                PlaceholderGap()
                            }
                            githubCard(issue, isSelected: isSelected && appModel.selectedItem == index, laneIndex: laneIndex)
                        }
                        if let p = placeholderIndex, p >= issues.count {
                            PlaceholderGap()
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
                .strokeBorder(
                    isSelected || isDropTarget
                        ? Color.accentColor.opacity(isSelected ? 0.85 : 0.55)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: isSelected || isDropTarget ? 1.5 : 1
                )
        )
        .background(laneFrameReporter(lane))
    }

    /// One card, with drag-and-drop: the floating copy, distortion, and
    /// settle animation come from the shared machinery in BoardView.
    @ViewBuilder
    private func githubCard(_ issue: GitHubIssue, isSelected: Bool, laneIndex: Int) -> some View {
        let dragging = appModel.drag?.itemID == String(issue.number) && appModel.drag?.settling == false
        GitHubCardView(issue: issue, isSelected: isSelected)
            .opacity(dragging ? 0.15 : 1)
            .gesture(boardDragGesture(itemID: String(issue.number), appModel: appModel, config: dragConfig(for: issue)))
            .background(cardFrameReporter(issue))
            .modifier(InstantTap(
                single: {
                    appModel.selectedLane = laneIndex
                    appModel.selectedItem = issues(inLaneIndexOf: laneIndex).firstIndex(where: { $0.number == issue.number }) ?? 0
                },
                double: {
                    appModel.selectedLane = laneIndex
                    appModel.selectedItem = issues(inLaneIndexOf: laneIndex).firstIndex(where: { $0.number == issue.number }) ?? 0
                    appModel.detailTarget = CursorPosition(lane: laneIndex, item: appModel.selectedItem)
                }
            ))
            .contextMenu {
                Button("Edit Issue…") {
                    appModel.editTarget = EditIssueTarget(
                        content: .githubIssue(account: account, board: model, issue: issue)
                    )
                }
            }
    }

    private func issues(inLaneIndexOf laneIndex: Int) -> [GitHubIssue] {
        guard model.lanes.indices.contains(laneIndex) else { return [] }
        return model.issues(inLane: model.lanes[laneIndex].id)
    }

    /// Where the placeholder gap renders in this lane (nil = no drop here).
    /// Cross-lane only — the dragged card isn't in this lane's list, so the
    /// insertion index maps directly onto the visible cards.
    private func insertionIndex(laneIndex: Int) -> Int? {
        guard let d = appModel.drag, !d.settling, let ins = d.insertion,
              ins.lane == laneIndex else { return nil }
        return ins.index
    }

    /// Hit-test the pointer against lane/card frames in board space.
    /// Same-lane drags return nil: the remote API can't reorder within a
    /// lane, so the card just settles back where it came from.
    private func computeInsertion(location: CGPoint, excluding itemID: String) -> DragInsertion? {
        guard model.lanes.count > 0 else { return nil }
        var laneHit: (index: Int, frame: CGRect)?
        for (i, lane) in model.lanes.enumerated() {
            guard let f = laneFrames[lane.id] else { continue }
            if location.x >= f.minX - 6 && location.x <= f.maxX + 6 {
                laneHit = (i, f)
                break
            }
        }
        guard let hit = laneHit else { return nil }
        // Same-lane drop: not supported remotely.
        if model.issues(inLane: model.lanes[hit.index].id).contains(where: { String($0.number) == itemID }) {
            return nil
        }
        let cards = model.issues(inLane: model.lanes[hit.index].id)
        var index = cards.count
        for (j, card) in cards.enumerated() {
            guard let cf = cardFrames[String(card.number)] else { continue }
            if location.y < cf.midY {
                index = j
                break
            }
        }
        return DragInsertion(lane: hit.index, index: index)
    }

    /// Board-specific drop behavior: optimistic transition to the target
    /// lane; cursor follows the dropped card.
    private func dragConfig(for issue: GitHubIssue) -> BoardDragConfig {
        BoardDragConfig(
            computeInsertion: { location, itemID in
                computeInsertion(location: location, excluding: itemID)
            },
            commit: { ins in
                guard model.lanes.indices.contains(ins.lane) else { return }
                let target = model.lanes[ins.lane].id
                Task { @MainActor in _ = await model.transition(issueNumber: issue.number, toLane: target) }
            },
            select: { ins in
                appModel.selectedLane = ins.lane
                DispatchQueue.main.async {
                    let list = self.issues(inLaneIndexOf: ins.lane)
                    appModel.selectedItem = list.firstIndex(where: { $0.number == issue.number }) ?? 0
                }
            }
        )
    }

    /// The floating dragged card, following the pointer with speed-based
    /// distortion, mirroring the local board's copy.
    @ViewBuilder
    private var floatingCard: some View {
        if let drag = appModel.drag,
           let frame = cardFrames[drag.itemID],
           let num = Int(drag.itemID),
           let issue = model.issues.first(where: { $0.number == num }) {
            GitHubCardView(issue: issue, isSelected: false)
                .frame(width: frame.width)
                .modifier(CardDistortion(vx: drag.smoothedVX))
                .offset(CGSize(width: frame.minX + drag.offset.width, height: frame.minY + drag.offset.height))
                .shadow(color: .black.opacity(0.28 * (drag.settling ? drag.settleOpacity : 1)), radius: 9, y: 5)
                .opacity(drag.settling ? drag.settleOpacity : 1)
                .allowsHitTesting(false)
        }
    }

    private func laneFrameReporter(_ lane: GitHubLane) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: LaneFramesKey.self,
                value: [lane.id: geo.frame(in: .named("board"))]
            )
        }
    }

    private func cardFrameReporter(_ issue: GitHubIssue) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CardFramesKey.self,
                value: [String(issue.number): geo.frame(in: .named("board"))]
            )
        }
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
    /// Optional repo label (mentions page shows cards from several repos —
    /// this mirrors how Jira cards carry their project key).
    var repoName: String? = nil

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
                if let repoName {
                    Text(repoName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
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