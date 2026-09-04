import SwiftUI

// MARK: - Frame preferences (for drag hit-testing)

struct LaneFramesKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct CardFramesKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Local board

struct BoardView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var model: AppModel
    @State private var laneFrames: [Int64: CGRect] = [:]
    @State private var cardFrames: [Int64: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            board
            floatingCard
        }
        .onAppear {
            model.clampSelection()
            installDetailResolver()
        }
    }

    /// Tell AppModel how to resolve a cursor position on this board, so the
    /// detail sheet can be presented from the RootView level.
    private func installDetailResolver() {
        model.resolveDetail = { target in
            taskAt(target).map { DetailSheetContent.localTask($0) }
        }
    }

    // MARK: Board

    private var board: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal]) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(store.lanes.enumerated()), id: \.element.id) { laneIndex, lane in
                        LaneView(
                            lane: lane,
                            laneIndex: laneIndex,
                            tasks: visibleTasks(in: lane),
                            model: model,
                            store: store,
                            computeInsertion: computeInsertion(location:excluding:)
                        )
                    }
                }
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .coordinateSpace(name: "board")
            .onPreferenceChange(LaneFramesKey.self) { laneFrames = $0 }
            .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
            .onChange(of: model.selectedLane) { _, _ in
                guard store.lanes.indices.contains(model.selectedLane) else { return }
                proxy.scrollTo(store.lanes[model.selectedLane].id, anchor: .center)
            }
        }
    }

    // MARK: Floating dragged card

    @ViewBuilder
    private var floatingCard: some View {
        if let drag = model.drag,
           !drag.settling,
           let frame = cardFrames[drag.taskID],
           let task = store.tasks.first(where: { $0.id == drag.taskID }) {
            TaskCardView(task: task, isSelected: false)
                .frame(width: frame.width)
                .modifier(CardDistortion(vx: drag.smoothedVX))
                .offset(CGSize(width: frame.minX + drag.offset.width, height: frame.minY + drag.offset.height))
                .shadow(color: .black.opacity(0.28), radius: 9, y: 5)
                .allowsHitTesting(false)
        } else if let drag = model.drag,
                  drag.settling,
                  let frame = cardFrames[drag.taskID],
                  let task = store.tasks.first(where: { $0.id == drag.taskID }) {
            TaskCardView(task: task, isSelected: false)
                .frame(width: frame.width)
                .modifier(CardDistortion(vx: drag.smoothedVX))
                .offset(CGSize(width: frame.minX + drag.offset.width, height: frame.minY + drag.offset.height))
                .shadow(color: .black.opacity(0.28 * drag.settleOpacity), radius: 9, y: 5)
                .opacity(drag.settleOpacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: Helpers

    private func visibleTasks(in lane: Lane) -> [TodoTask] {
        let f = model.filterText
        let all = store.laneTasks(lane.id)
        guard !f.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(f) ||
            $0.notes.localizedCaseInsensitiveContains(f)
        }
    }

    func taskAt(_ position: CursorPosition) -> TodoTask? {
        guard store.lanes.indices.contains(position.lane) else { return nil }
        let lane = store.lanes[position.lane]
        let items = visibleTasks(in: lane)
        return items.indices.contains(position.item) ? items[position.item] : nil
    }

    /// Compute the drop target for a pointer location in board space.
    func computeInsertion(location: CGPoint, excluding taskID: Int64) -> DragInsertion? {
        guard store.lanes.count > 0 else { return nil }
        // Find the lane under the pointer (with a small grab margin).
        var laneHit: (index: Int, frame: CGRect)?
        for (i, lane) in store.lanes.enumerated() {
            guard let f = laneFrames[lane.id] else { continue }
            if location.x >= f.minX - 6 && location.x <= f.maxX + 6 {
                laneHit = (i, f)
                break
            }
        }
        guard let hit = laneHit else { return nil }

        let lane = store.lanes[hit.index]
        let cards = store.laneTasks(lane.id).sorted { $0.position < $1.position }
        let draggingWithinLane = store.tasks.first { $0.id == taskID }?.laneID == lane.id
        let dragIdx = draggingWithinLane ? cards.firstIndex { $0.id == taskID } ?? 0 : -1

        // Insertion index semantics: position within the lane's list
        // EXCLUDING the dragged task (matches store.moveTask(at:)).
        // Default = append: after all others (same lane) or at the end
        // (cross-lane, where the dragged task isn't in the list anyway).
        var index = draggingWithinLane ? max(cards.count - 1, 0) : cards.count
        for (j, card) in cards.enumerated() {
            guard card.id != taskID else { continue }
            // Only visible cards have frames; invisible (filtered-out) cards
            // still occupy list slots, which `index` accounts for.
            guard let cf = cardFrames[card.id] else { continue }
            if location.y < cf.midY {
                // Skip the dragged task's own slot when counting predecessors.
                index = (draggingWithinLane && dragIdx < j) ? j - 1 : j
                break
            }
        }
        return DragInsertion(lane: hit.index, index: index)
    }
}

// MARK: - Lane

struct LaneView: View {
    let lane: Lane
    let laneIndex: Int
    let tasks: [TodoTask]
    @ObservedObject var model: AppModel
    @ObservedObject var store: TodoStore
    var computeInsertion: (CGPoint, Int64) -> DragInsertion?

    @State private var renameFieldVisible = false
    @State private var laneNameDraft = ""
    @State private var newTaskTitle = ""

    private var insertion: DragInsertion? {
        guard let d = model.drag, !d.settling else { return nil }
        return d.insertion?.lane == laneIndex ? d.insertion : nil
    }

    /// Map the drag insertion (unfiltered, excluding the dragged task) to an
    /// index within the *visible* task list so the placeholder renders where
    /// the card will actually land.
    private var placeholderVisibleIndex: Int? {
        guard let ins = insertion, let d = model.drag else { return nil }
        let others = store.laneTasks(lane.id).filter { $0.id != d.taskID }
        guard ins.index <= others.count else { return nil }
        let visibleIDs = Set(tasks.map(\.id))
        let p = others[..<ins.index].filter { visibleIDs.contains($0.id) }.count
        // Same-lane downward drag: the dragged card still occupies its visible
        // slot above the insertion point, so the rendered list keeps one extra
        // slot — the gap belongs one further down.
        if let q = tasks.firstIndex(where: { $0.id == d.taskID }), p > q {
            return p + 1
        }
        return p
    }

    private var isDropTarget: Bool {
        guard let d = model.drag, !d.settling, let ins = d.insertion else { return false }
        return ins.lane == laneIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            // Cards scroll vertically within the lane so a tall lane can't
            // inflate the whole board's ideal height past the window (see
            // JiraBoardView for the blank-window fallout of that).
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                            if placeholderVisibleIndex == index {
                                PlaceholderGap()
                            }
                            card(task, at: index)
                        }
                        if let p = placeholderVisibleIndex, p >= tasks.count {
                            PlaceholderGap()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: model.selectedItem) { _, _ in
                    guard model.selectedLane == laneIndex,
                          tasks.indices.contains(model.selectedItem) else { return }
                    proxy.scrollTo(tasks[model.selectedItem].id, anchor: .center)
                }
            }

            if model.quickAddLane == laneIndex {
                quickAddField
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
                    model.selectedLane == laneIndex
                        ? Color.accentColor.opacity(0.85)
                        : (isDropTarget ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.5)),
                    lineWidth: model.selectedLane == laneIndex || isDropTarget ? 1.5 : 1
                )
        )
        .background(laneFrameReporter)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if renameFieldVisible {
                TextField("Lane name", text: $laneNameDraft, onCommit: {
                    if !laneNameDraft.isEmpty {
                        try? store.renameLane(lane.id, to: laneNameDraft)
                    }
                    renameFieldVisible = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
            } else {
                Text(lane.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        laneNameDraft = lane.name
                        renameFieldVisible = true
                    }
                Spacer(minLength: 0)
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ task: TodoTask, at index: Int) -> some View {
        let isSelected = model.selectedLane == laneIndex && model.selectedItem == index
        let renaming = model.renameTarget == CursorPosition(lane: laneIndex, item: index)
        let dragging = model.drag?.taskID == task.id && model.drag?.settling == false

        Group {
            if renaming {
                RenameField(text: task.title) { newTitle in
                    if !newTitle.isEmpty {
                        try? store.updateTask(task.id, title: newTitle)
                    }
                    model.renameTarget = nil
                } onCancel: {
                    model.renameTarget = nil
                }
                .padding(.vertical, 2)
            } else {
                TaskCardView(task: task, isSelected: isSelected)
                    .contentShape(Rectangle())
                    .opacity(dragging ? 0.15 : 1)
                    .gesture(dragGesture(for: task))
                    .modifier(InstantTap(
                        single: {
                            model.selectedLane = laneIndex
                            model.selectedItem = index
                        },
                        double: {
                            model.selectedLane = laneIndex
                            model.selectedItem = index
                            model.detailTarget = CursorPosition(lane: laneIndex, item: index)
                        }
                    ))
                    .contextMenu {
                        Button("Delete Task…", role: .destructive) {
                            model.deleteTarget = DeleteTarget(content: .localTask(task))
                        }
                    }
            }
        }
    }

    private func dragGesture(for task: TodoTask) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .onChanged { value in
                if let d = model.drag, d.taskID != task.id, !d.settling {
                    return // only one drag at a time
                }
                if model.drag == nil {
                    model.drag = DragSession(
                        taskID: task.id,
                        offset: .zero,
                        smoothedVX: 0,
                        insertion: nil,
                        settling: false
                    )
                }
                guard model.drag?.taskID == task.id else { return }
                var d = model.drag!
                d.offset = value.translation
                // EMA smoothing for the distortion input.
                d.smoothedVX = d.smoothedVX * 0.78 + value.velocity.width * 0.22
                d.insertion = computeInsertion(value.location, task.id)
                model.drag = d
            }
            .onEnded { _ in
                guard let d = model.drag, d.taskID == task.id, !d.settling else { return }

                // Commit the move. `ins.index` is an insertion index in the
                // target lane excluding the moved task (matches moveTask(at:)).
                if let ins = d.insertion, store.lanes.indices.contains(ins.lane) {
                    let targetLane = store.lanes[ins.lane]
                    _ = try? store.moveTask(task.id, toLane: targetLane.id, at: ins.index)
                    model.selectedLane = ins.lane
                    // Cursor lands on the dropped task, in the visible (filtered) space.
                    let f = model.filterText
                    let all = store.laneTasks(targetLane.id)
                    let visible = f.isEmpty ? all : all.filter {
                        $0.title.localizedCaseInsensitiveContains(f) ||
                        $0.notes.localizedCaseInsensitiveContains(f)
                    }
                    model.selectedItem = visible.firstIndex { $0.id == task.id } ?? 0
                }

                // Spring the floating copy onto its slot while fading it out.
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                    model.drag?.offset = .zero
                    model.drag?.smoothedVX = 0
                    model.drag?.settling = true
                    model.drag?.settleOpacity = 0
                }
                let tid = task.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    if model.drag?.taskID == tid {
                        model.drag = nil
                    }
                }
            }
    }

    // MARK: Quick add

    private var quickAddField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("New task…", text: $newTaskTitle, onCommit: {
                let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    _ = try? store.addTask(title: title, laneID: lane.id)
                }
                newTaskTitle = ""
                model.quickAddLane = nil
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: Frame reporting

    private var laneFrameReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: LaneFramesKey.self,
                value: [lane.id: geo.frame(in: .named("board"))]
            )
        }
    }
}

// MARK: - Placeholder

struct PlaceholderGap: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.10))
            .frame(height: 46)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

// MARK: - Card

struct TaskCardView: View {
    let task: TodoTask
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if task.completedAt != nil {
                Label("done", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
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
        .background(cardFrameReporter)
    }

    private var cardFrameReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CardFramesKey.self,
                value: [task.id: geo.frame(in: .named("board"))]
            )
        }
    }
}

// MARK: - Rename field

struct RenameField: View {
    @State var text: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: $text, onCommit: { onCommit(text) })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($focused)
            .onAppear { focused = true }
            .onExitCommand { onCancel() }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var filterFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Filter (/)", text: $model.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onExitCommand {
                    filterFocused = false
                    model.filterText = ""
                }
            if !model.filterText.isEmpty {
                Button {
                    model.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onChange(of: model.filterFocusToggle) { _ in
            filterFocused = true
        }
    }
}

// MARK: - Instant tap select

/// Subtle hover affordance for board cards: a soft accent border while the
/// pointer is over the card. Full-strength selection border wins visually.
/// Instant (no animation) to match the app's interaction model.
struct CardHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(isHovered ? 0.45 : 0), lineWidth: 1.5)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func cardHover() -> some View { modifier(CardHover()) }
}

/// Web-style pointing-hand cursor over clickable items. Hover-enter also
/// re-renders cards (CardHover border), and AppKit's cursor-rect update
/// after that render resets whatever `.set()` installed — so the cursor is
/// re-asserted on every mouse move via onContinuousHover, and `.set()`
/// (not push/pop) keeps a vanishing card from unbalancing the cursor stack.
struct HoverPointingHand: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                DispatchQueue.main.async {
                    hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    func pointingHandOnHover() -> some View { modifier(HoverPointingHand()) }
}

/// Single-click select + double-click detail with no disambiguation delay.
/// SwiftUI's count-1/count-2 tap pair waits for the double-click window
/// before firing the single tap, which makes mouse selection feel laggy.
/// State is per card, so two fast clicks on different cards never collide.
/// Cards are the board's primary clickable items, so they also get the
/// pointing-hand cursor here.
struct InstantTap: ViewModifier {
    let single: () -> Void
    let double: () -> Void
    @State private var lastTap: Date?

    func body(content: Content) -> some View {
        content.onTapGesture {
            let now = Date()
            if let previous = lastTap, now.timeIntervalSince(previous) < 0.4 {
                lastTap = nil
                double()
            } else {
                lastTap = now
                single()
            }
        }
        .pointingHandOnHover()
    }
}

// MARK: - Help overlay

struct HelpOverlay: View {
    enum Surface {
        case local
        case jira
        case github
    }

    let surface: Surface

    private var keys: [(String, String)] {
        switch surface {
        case .local:
            [
                ("j/k, ↓/↑", "cursor down / up"),
                ("h/l, ←/→", "lane left / right"),
                ("J/K, ⇧↓/⇧↑", "move task down / up"),
                ("H/L, ⇧←/⇧→", "move task to left / right lane"),
                ("n", "add task in current lane"),
                ("Shift+N", "add lane"),
                ("e", "rename task"),
                ("Enter", "task detail"),
                ("d d", "delete task"),
                ("g g / G", "first / last task"),
                ("1-9", "jump to lane"),
                ("⌘1-9", "jump to board"),
                ("/", "filter tasks"),
                ("?", "toggle this help"),
                ("Esc", "cancel / clear"),
            ]
        case .jira:
            [
                ("j/k, ↓/↑", "cursor down / up"),
                ("h/l, ←/→", "lane left / right"),
                ("H/L, ⇧←/⇧→", "move issue to adjacent lane (Jira transition)"),
                ("Enter", "issue detail"),
                ("n", "new issue"),
                ("d d", "delete issue"),
                ("g g / G", "first / last issue"),
                ("1-9", "jump to lane"),
                ("⌘1-9", "jump to board"),
                ("/", "filter issues"),
                ("?", "toggle this help"),
                ("Esc", "cancel / clear"),
            ]
        case .github:
            [
                ("j/k, ↓/↑", "cursor down / up"),
                ("h/l, ←/→", "lane left / right"),
                ("H/L, ⇧←/⇧→", "move issue to adjacent lane (state change)"),
                ("Enter", "issue detail"),
                ("n", "new issue"),
                ("g g / G", "first / last issue"),
                ("1-9", "jump to lane"),
                ("⌘1-9", "jump to board"),
                ("/", "filter issues"),
                ("?", "toggle this help"),
                ("Esc", "cancel / clear"),
            ]
        }
    }

    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard")
                .font(.system(size: 13, weight: .semibold))
            ForEach(keys, id: \.0) { key, desc in
                HStack {
                    Text(key)
                        .font(.system(size: 12, weight: .medium).monospaced())
                        .frame(width: 110, alignment: .leading)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text(surface == .local
                 ? "Drag cards between lanes — flick fast and they lean."
                 : (surface == .jira
                    ? "H/L performs a live Jira status transition."
                    : "H/L changes issue state: Open → Completed → Not Planned."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        )
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture { model.showHelp = false }
    }
}