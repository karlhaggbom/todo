import SwiftUI

// MARK: - Task detail sheet (local tasks)

struct TaskDetailView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let task: TodoTask

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Task")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Details")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 16) {
                    Label(
                        "\(laneName(task.laneID))",
                        systemImage: "square.split.3x1"
                    )
                    Label(
                        task.createdAt.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "clock"
                    )
                    if let done = task.completedAt {
                        Label(
                            "Done \(done.formatted(date: .abbreviated, time: .omitted))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                if confirmDelete {
                    Text("Delete this task?")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Yes, delete", role: .destructive) {
                        try? store.deleteTask(task.id)
                        dismiss()
                    }
                    Button("Cancel") {
                        confirmDelete = false
                    }
                    Spacer()
                } else {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Spacer()
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 420, height: 380)
        .onAppear {
            title = task.title
            notes = task.notes
        }
        .onChange(of: task.id) { _ in
            title = task.title
            notes = task.notes
        }
    }

    private func laneName(_ laneID: Int64) -> String {
        store.lanes.first { $0.id == laneID }?.name ?? "—"
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            try? store.updateTask(task.id, title: trimmedTitle, notes: notes)
        }
    }
}

// MARK: - Local board keyboard navigation

/// Adapts the local board to the Vimium-style keyboard surface.
/// `item` indexes run over the *filtered* task list when a filter is active.
final class LocalBoardModel: KeyboardNavigable {
    let store: TodoStore
    let model: AppModel

    init(store: TodoStore, model: AppModel) {
        self.store = store
        self.model = model
    }

    var navLaneCount: Int { store.lanes.count }

    private func filteredTasks(inLane laneID: Int64) -> [TodoTask] {
        let all = store.laneTasks(laneID)
        guard !model.filterText.isEmpty else { return all }
        let f = model.filterText
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(f) ||
            $0.notes.localizedCaseInsensitiveContains(f)
        }
    }

    func navItemCount(lane: Int) -> Int {
        guard store.lanes.indices.contains(lane) else { return 0 }
        return filteredTasks(inLane: store.lanes[lane].id).count
    }

    func navMove(lane: Int, item: Int) -> Bool {
        model.clampSelection()
        return true
    }

    func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool {
        guard store.lanes.indices.contains(lane) else { return false }
        let laneID = store.lanes[lane].id
        let visible = filteredTasks(inLane: laneID)
        guard visible.indices.contains(item) else { return false }
        let taskID = visible[item].id

        if toLaneDelta != 0 {
            let target = lane + toLaneDelta
            guard store.lanes.indices.contains(target) else { return false }
            _ = try? store.moveTask(taskID, toLane: store.lanes[target].id)
            return true
        } else if itemDelta != 0 {
            // Map visible index to real index in the full lane list.
            let all = store.laneTasks(laneID)
            guard let realIndex = all.firstIndex(where: { $0.id == taskID }) else { return false }
            let target = realIndex + itemDelta
            guard target >= 0, target < all.count else { return false }
            _ = try? store.moveTask(taskID, toLane: laneID, at: target)
            return true
        }
        return false
    }

    func navOpenDetail(lane: Int, item: Int) {
        guard store.lanes.indices.contains(lane),
              filteredTasks(inLane: store.lanes[lane].id).indices.contains(item) else { return }
        model.detailTarget = CursorPosition(lane: lane, item: item)
    }

    func navBeginRename(lane: Int, item: Int) {
        guard store.lanes.indices.contains(lane),
              filteredTasks(inLane: store.lanes[lane].id).indices.contains(item) else { return }
        model.renameTarget = CursorPosition(lane: lane, item: item)
    }

    /// Delete the task under the cursor (`dd`). Returns false when the
    /// cursor sits on a filtered-out or missing item.
    func navDelete(lane: Int, item: Int) -> Bool {
        guard store.lanes.indices.contains(lane) else { return false }
        let laneID = store.lanes[lane].id
        let visible = filteredTasks(inLane: laneID)
        guard visible.indices.contains(item) else { return false }
        _ = try? store.deleteTask(visible[item].id)
        return true
    }
}