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

    // Drag-and-drop (same machinery as the local board): frames are
    // reported in the "board" coordinate space for hit-testing.
    @State private var laneFrames: [String: CGRect] = [:]
    @State private var cardFrames: [String: CGRect] = [:]

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
            ZStack(alignment: .topLeading) {
                boardBody
                floatingCard
            }
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
            appModel.registerCreateIssueHandler(owner: model) {
                appModel.createTarget = CreateIssueTarget(content: .jiraIssue(account: account, board: model))
            }
        }
        .onDisappear {
            appModel.clearCreateIssueHandler(owner: model)
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
            Toggle("My tickets only", isOn: $model.mineOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Only show issues assigned to you")
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
                    .coordinateSpace(name: "board")
                    .onPreferenceChange(LaneFramesKey.self) { laneFrames = $0 }
                    .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
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
        let isDropTarget = appModel.drag?.settling == false
            && appModel.drag?.insertion?.lane == laneIndex
        let placeholderIndex = insertionIndex(laneIndex: laneIndex)
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
                            if placeholderIndex == index {
                                PlaceholderGap()
                            }
                            jiraCard(issue, isSelected: isSelected && appModel.selectedItem == index, laneIndex: laneIndex)
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
        .background(laneFrameReporter(status))
    }

    /// One card, with drag-and-drop: the floating copy, distortion, and
    /// settle animation come from the shared machinery in BoardView.
    @ViewBuilder
    private func jiraCard(_ issue: JiraIssue, isSelected: Bool, laneIndex: Int) -> some View {
        let dragging = appModel.drag?.itemID == issue.key && appModel.drag?.settling == false
        JiraCardView(issue: issue, isSelected: isSelected)
            .opacity(dragging ? 0.15 : 1)
            .gesture(boardDragGesture(itemID: issue.key, appModel: appModel, config: dragConfig(for: issue)))
            .background(cardFrameReporter(issue))
            .modifier(InstantTap(
                single: {
                    appModel.selectedLane = laneIndex
                    appModel.selectedItem = issues(inStatusIndexOf: laneIndex).firstIndex(where: { $0.key == issue.key }) ?? 0
                },
                double: {
                    appModel.selectedLane = laneIndex
                    appModel.selectedItem = issues(inStatusIndexOf: laneIndex).firstIndex(where: { $0.key == issue.key }) ?? 0
                    appModel.detailTarget = CursorPosition(lane: laneIndex, item: appModel.selectedItem)
                }
            ))
            .contextMenu {
                Button("Edit Issue…") {
                    appModel.editTarget = EditIssueTarget(
                        content: .jiraIssue(account: account, board: model, issue: issue)
                    )
                }
                Button("Delete Issue…", role: .destructive) {
                    appModel.deleteTarget = DeleteTarget(
                        content: .jiraIssue(account: account, board: model, issue: issue)
                    )
                }
            }
    }

    private func issues(inStatusIndexOf laneIndex: Int) -> [JiraIssue] {
        guard model.statuses.indices.contains(laneIndex) else { return [] }
        return model.issues(inStatus: model.statuses[laneIndex].name)
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
        guard model.statuses.count > 0 else { return nil }
        var laneHit: (index: Int, frame: CGRect)?
        for (i, status) in model.statuses.enumerated() {
            guard let f = laneFrames[status.id] else { continue }
            if location.x >= f.minX - 6 && location.x <= f.maxX + 6 {
                laneHit = (i, f)
                break
            }
        }
        guard let hit = laneHit else { return nil }
        // Same-lane drop: not supported remotely.
        if model.issues(inStatus: model.statuses[hit.index].name).contains(where: { $0.key == itemID }) {
            return nil
        }
        let cards = model.issues(inStatus: model.statuses[hit.index].name)
        var index = cards.count
        for (j, card) in cards.enumerated() {
            guard let cf = cardFrames[card.key] else { continue }
            if location.y < cf.midY {
                index = j
                break
            }
        }
        return DragInsertion(lane: hit.index, index: index)
    }

    /// Board-specific drop behavior: optimistic transition to the target
    /// status lane; cursor follows the dropped card.
    private func dragConfig(for issue: JiraIssue) -> BoardDragConfig {
        BoardDragConfig(
            computeInsertion: { location, itemID in
                computeInsertion(location: location, excluding: itemID)
            },
            commit: { ins in
                guard model.statuses.indices.contains(ins.lane) else { return }
                let target = model.statuses[ins.lane].name
                Task { @MainActor in _ = await model.transition(issueKey: issue.key, toStatus: target) }
            },
            select: { ins in
                appModel.selectedLane = ins.lane
                DispatchQueue.main.async {
                    let list = self.issues(inStatusIndexOf: ins.lane)
                    appModel.selectedItem = list.firstIndex(where: { $0.key == issue.key }) ?? 0
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
           let issue = model.issues.first(where: { $0.key == drag.itemID }) {
            JiraCardView(issue: issue, isSelected: false)
                .frame(width: frame.width)
                .modifier(CardDistortion(vx: drag.smoothedVX))
                .offset(CGSize(width: frame.minX + drag.offset.width, height: frame.minY + drag.offset.height))
                .shadow(color: .black.opacity(0.28 * (drag.settling ? drag.settleOpacity : 1)), radius: 9, y: 5)
                .opacity(drag.settling ? drag.settleOpacity : 1)
                .allowsHitTesting(false)
        }
    }

    private func laneFrameReporter(_ status: JiraStatus) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: LaneFramesKey.self,
                value: [status.id: geo.frame(in: .named("board"))]
            )
        }
    }

    private func cardFrameReporter(_ issue: JiraIssue) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CardFramesKey.self,
                value: [issue.key: geo.frame(in: .named("board"))]
            )
        }
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