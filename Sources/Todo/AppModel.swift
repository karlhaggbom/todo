import Foundation
import Combine
import AppKit

// MARK: - Detail sheet content

/// What the detail sheet shows for a given cursor position. Resolved lazily
/// by the active board so presentation can live at the RootView level.
enum DetailSheetContent {
    case localTask(TodoTask)
    case jiraTicket(account: JiraAccount, board: JiraBoardModel, issue: JiraIssue)
    case githubIssue(account: GitHubAccount, board: GitHubBoardModel, issue: GitHubIssue)
}

/// Create-issue sheet target: the board model is passed so the sheet can
/// insert the created issue directly, presented from the RootView level.
struct CreateIssueTarget: Identifiable {
    enum Content {
        case jiraIssue(account: JiraAccount, board: JiraBoardModel)
        case githubIssue(account: GitHubAccount, board: GitHubBoardModel)
    }
    let id = UUID()
    let content: Content
}

/// Delete-confirmation target, presented from RootView. GitHub issues
/// can't be deleted through the REST API (only closed — the existing lane
/// transitions), so GitHub boards never produce a delete target.
struct DeleteTarget: Identifiable {
    enum Content {
        case localTask(TodoTask)
        case jiraIssue(account: JiraAccount, board: JiraBoardModel, issue: JiraIssue)
    }
    let id = UUID()
    let content: Content
}

/// Edit-issue sheet target, presented from RootView. Reuses the create
/// sheets in edit mode (Save instead of Create). Reached from card
/// context menus and the detail views.
struct EditIssueTarget: Identifiable {
    enum Content {
        case jiraIssue(account: JiraAccount, board: JiraBoardModel, issue: JiraIssue)
        case githubIssue(account: GitHubAccount, board: GitHubBoardModel, issue: GitHubIssue)
    }
    let id = UUID()
    let content: Content
}

/// Direct issue-detail sheet target. Unlike `detailTarget` (a cursor
/// position resolved by the active board), this carries the content
/// itself — used from the mentions pages, which have no board context
/// to resolve from.
struct IssueDetailTarget: Identifiable {
    let id = UUID()
    let content: DetailSheetContent
}

// MARK: - Keyboard navigation abstraction

/// A surface that can be driven by Vimium-style keys.
/// Both the local board and Jira boards conform to this.
protocol KeyboardNavigable: AnyObject {
    /// Number of lanes currently visible.
    var navLaneCount: Int { get }
    /// Number of items in the given lane.
    func navItemCount(lane: Int) -> Int
    /// Move the cursor. Returns true if the key was consumed.
    func navMove(lane: Int, item: Int) -> Bool
    /// Move the item at (lane, item) to another lane / offset within lane.
    func navMoveItem(lane: Int, item: Int, toLaneDelta: Int, itemDelta: Int) -> Bool
    /// Open the detail view for the cursor.
    func navOpenDetail(lane: Int, item: Int)
    /// Rename the item at the cursor (inline edit).
    func navBeginRename(lane: Int, item: Int)
}

// MARK: - Keyboard event routing

enum KeyboardRouter {
    /// True if the event should be routed to app shortcuts (not text input).
    static func shouldIntercept(_ event: NSEvent) -> Bool {
        // Never intercept while a text field has focus, except Esc which views handle.
        if event.window?.firstResponder is NSTextView { return false }
        // Command-modified keys go to the system (Cmd-Q, Cmd-W, ...).
        if event.modifierFlags.contains(.command) { return false }
        // Only plain character keys (plus shift for H/L/J/K).
        // Option-modified arrows stay with the system (word navigation).
        if event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers.map({ ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"].contains($0) }) == true {
            return false
        }
        return event.charactersIgnoringModifiers != nil
    }
}

// MARK: - Cursor target

/// Cursor position (lane + item) used for rename/detail targets.
struct CursorPosition: Identifiable, Equatable {
    var lane: Int
    var item: Int
    var id: String { "\(lane):\(item)" }
}

/// Where the card would land if dropped now.
struct DragInsertion: Equatable {
    var lane: Int
    var index: Int
}

// MARK: - Drag session

/// Live state for one drag of a card across the board. `itemID` is a
/// string so the same machinery serves every board: "\(task.id)" (local),
/// the Jira issue key, "\(number)" (GitHub).
struct DragSession {
    let itemID: String
    /// Translation from the card's resting position (used for the floating copy).
    var offset: CGSize
    /// Smoothed (EMA) horizontal velocity used for distortion.
    var smoothedVX: CGFloat
    /// Target insertion: lane index + item index.
    var insertion: DragInsertion?
    /// When true, the card springs back to its slot and fades out briefly.
    var settling: Bool
    /// Fades the floating copy while settling (underlying card shows through).
    var settleOpacity: Double = 1
}

// MARK: - App model

/// Holds selection, keyboard state, drag state, and UI toggles.
public final class AppModel: ObservableObject {
    public init() {}
    /// The main window, captured once at launch so background-click
    /// dismissal can tell "click behind the sheet" apart from clicks in
    /// the sheet, menus, or popovers (all separate NSWindows).
    weak var mainWindow: NSWindow?

    // Board cursor
    @Published var selectedLane: Int = 0
    @Published var selectedItem: Int = 0

    // Drag
    @Published var drag: DragSession?

    // UI toggles
    @Published var showHelp = false
    @Published var filterText = ""
    @Published var quickAddLane: Int?   // lane showing the inline add field
    @Published var renameTarget: CursorPosition?
    @Published var detailTarget: CursorPosition?
    @Published var newLaneFieldVisible = false
    @Published var selectedSidebarSection: SidebarSection = .local

    // `dd` state
    private var pendingDeleteKey = false
    private var deleteResetWorkItem: DispatchWorkItem?

    /// Content for the detail sheet, resolved by the active surface when the
    /// sheet is about to present. Keeping resolution in a closure lets the
    /// sheet itself be presented from the RootView level — presenting sheets
    /// from inside the NavigationSplitView *detail* content is fragile on
    /// macOS 15 (the whole window's SwiftUI content can vanish).
    var resolveDetail: ((CursorPosition) -> DetailSheetContent?)? = nil

    /// Create-issue sheet, presented from RootView.
    @Published var createTarget: CreateIssueTarget?
    @Published var editTarget: EditIssueTarget?
    @Published var issueDetailTarget: IssueDetailTarget?
    /// Delete-confirmation sheet, presented from RootView.
    @Published var deleteTarget: DeleteTarget?
    /// Set by the active board view (like `navigable`); the "n" key invokes it.
    /// nil on the local board (which already has quick-add via "n").
    ///
    /// Registration is owner-tagged: SwiftUI can fire the incoming board's
    /// onAppear *before* the outgoing board's onDisappear, so a blind `= nil`
    /// on disappear would erase the handler the new board just registered.
    var createIssueHandler: (() -> Void)? = nil
    private var createIssueOwner: ObjectIdentifier? = nil

    func registerCreateIssueHandler(owner: AnyObject, handler: @escaping () -> Void) {
        createIssueOwner = ObjectIdentifier(owner)
        createIssueHandler = handler
    }

    func clearCreateIssueHandler(owner: AnyObject) {
        guard createIssueOwner == ObjectIdentifier(owner) else { return }
        createIssueHandler = nil
        createIssueOwner = nil
    }

    /// The currently active navigable surface (local board or a Jira board).
    var navigable: (() -> KeyboardNavigable?)? = nil

    // MARK: Cursor helpers

    /// Interrupt pending `dd`/`gg` sequences (e.g. when typing in a text field).
    func resetPendingSequences() {
        pendingDeleteKey = false
        deleteResetWorkItem?.cancel()
        pendingG = false
        gResetWorkItem?.cancel()
    }

    func clampSelection() {
        guard let nav = navigable?(), nav.navLaneCount > 0 else { return }
        selectedLane = min(max(selectedLane, 0), nav.navLaneCount - 1)
        let count = nav.navItemCount(lane: selectedLane)
        if count == 0 {
            selectedItem = 0
        } else {
            selectedItem = min(max(selectedItem, 0), count - 1)
        }
    }

    // MARK: Key handling

    /// Handle a key event routed from the local monitor. Returns true if consumed.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard KeyboardRouter.shouldIntercept(event) else { return false }
        let raw = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Map arrow keys onto their hjkl equivalents (shift kept below).
        let key: String
        switch raw {
        case "\u{F701}": key = "j" // down
        case "\u{F700}": key = "k" // up
        case "\u{F703}": key = "l" // right
        case "\u{F702}": key = "h" // left
        default: key = raw
        }
        let shift = event.modifierFlags.contains(.shift)

        // Multi-key sequences reset when interrupted by another key.
        if key != "d" {
            pendingDeleteKey = false
            deleteResetWorkItem?.cancel()
        }
        if key != "g" {
            pendingG = false
            gResetWorkItem?.cancel()
        }

        switch key {
        case "j":
            if shift { moveItem(0, +1) } else { moveCursor(0, +1) }
        case "k":
            if shift { moveItem(0, -1) } else { moveCursor(0, -1) }
        case "h":
            if shift { moveItem(-1, 0) } else { moveLane(-1) }
        case "l":
            if shift { moveItem(+1, 0) } else { moveLane(+1) }
        case "d":
            return handleDeleteKey()
        case "g":
            if shift { // G = last item
                guard let nav = navigable?() else { return false }
                let count = nav.navItemCount(lane: selectedLane)
                if count > 0 { selectedItem = count - 1; _ = nav.navMove(lane: selectedLane, item: selectedItem) }
                return true
            }
            // `gg` = first item (two presses within 0.3s)
            if pendingG {
                pendingG = false
                gResetWorkItem?.cancel()
                selectedItem = 0
                _ = navigable?().map { _ = $0.navMove(lane: selectedLane, item: 0) }
            } else {
                pendingG = true
                let work = DispatchWorkItem { [weak self] in self?.pendingG = false }
                gResetWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        case "?":
            showHelp.toggle()
        case "n":
            if shift {
                newLaneFieldVisible.toggle()
            } else if let createIssueHandler {
                // Jira/GitHub boards: the create-issue sheet.
                Diag.log.info("n: create handler present")
                createIssueHandler()
            } else {
                // Local board: inline quick-add in the current lane.
                Diag.log.info("n: no create handler, quick-add")
                quickAddLane = quickAddLane == selectedLane ? nil : selectedLane
            }
        case "e":
            beginRename()
        case "\r", "\n":
            openDetail()
        case "/":
            // Focus filter; views observe filterText focus via scenePhase-like hacks,
            // so we simply set a flag consumed by FilterBar.
            filterFocusToggle.toggle()
        case "\u{1b}":
            quickAddLane = nil
            renameTarget = nil
            filterText = ""
            showHelp = false
        case "1"..."9":
            if let lane = Int(key), let nav = navigable?(), lane - 1 < nav.navLaneCount {
                selectedLane = lane - 1
                selectedItem = 0
                _ = nav.navMove(lane: selectedLane, item: 0)
            }
        default:
            return false
        }
        return true
    }

    private var pendingG = false
    private var gResetWorkItem: DispatchWorkItem?

    private func handleDeleteKey() -> Bool {
        if pendingDeleteKey {
            // `dd` — ask for confirmation before deleting the cursor item;
            // one stray sequence shouldn't lose a ticket.
            pendingDeleteKey = false
            deleteResetWorkItem?.cancel()
            if let nav = navigable?(), nav.navItemCount(lane: selectedLane) > selectedItem {
                let cursor = CursorPosition(lane: selectedLane, item: selectedItem)
                if let content = resolveDetail?(cursor), let target = Self.deleteTarget(from: content) {
                    deleteTarget = target
                }
            }
            return true
        }
        pendingDeleteKey = true
        deleteResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingDeleteKey = false }
        deleteResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        return true
    }

    /// Map a resolved detail target onto a deletable one (GitHub: none).
    private static func deleteTarget(from content: DetailSheetContent) -> DeleteTarget? {
        switch content {
        case .localTask(let task):
            return DeleteTarget(content: .localTask(task))
        case .jiraTicket(let account, let board, let issue):
            return DeleteTarget(content: .jiraIssue(account: account, board: board, issue: issue))
        case .githubIssue:
            return nil
        }
    }

    // MARK: Cursor ops

    private func moveCursor(_ laneDelta: Int, _ itemDelta: Int) {
        guard let nav = navigable?() else { return }
        var lane = selectedLane
        var item = selectedItem
        if itemDelta != 0 {
            item += itemDelta
            let count = nav.navItemCount(lane: lane)
            if item >= count { item = count - 1 }
            if item < 0 { item = 0 }
        }
        if laneDelta != 0 {
            // Preserve vertical position approximately.
            lane = min(max(lane + laneDelta, 0), nav.navLaneCount - 1)
            let count = nav.navItemCount(lane: lane)
            item = min(item, max(count - 1, 0))
        }
        selectedLane = lane
        selectedItem = item
        _ = nav.navMove(lane: lane, item: item)
    }

    private func moveLane(_ delta: Int) {
        guard let nav = navigable?() else { return }
        let lane = min(max(selectedLane + delta, 0), nav.navLaneCount - 1)
        selectedLane = lane
        let count = nav.navItemCount(lane: lane)
        selectedItem = min(selectedItem, max(count - 1, 0))
        _ = nav.navMove(lane: lane, item: selectedItem)
    }

    private func moveItem(_ laneDelta: Int, _ itemDelta: Int) {
        guard let nav = navigable?() else { return }
        guard nav.navItemCount(lane: selectedLane) > selectedItem else { return }
        if !nav.navMoveItem(lane: selectedLane, item: selectedItem, toLaneDelta: laneDelta, itemDelta: itemDelta) {
            return
        }
        selectedLane = min(max(selectedLane + laneDelta, 0), nav.navLaneCount - 1)
        if itemDelta != 0 { selectedItem += itemDelta }
        clampSelection()
    }

    private func beginRename() {
        renameTarget = CursorPosition(lane: selectedLane, item: selectedItem)
    }

    private func openDetail() {
        guard let nav = navigable?(), nav.navItemCount(lane: selectedLane) > selectedItem else { return }
        detailTarget = CursorPosition(lane: selectedLane, item: selectedItem)
    }

    // MARK: Misc

    @Published var filterFocusToggle = false
}

// MARK: - Sidebar section

enum SidebarSection: Hashable {
    case local
    case jiraSpace(JiraSpace.ID)
    case jiraActivity(JiraAccount.ID)
    case githubSpace(GitHubRepo.ID)
    case githubActivity(GitHubAccount.ID)
}