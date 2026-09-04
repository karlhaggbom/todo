import AppKit
import Combine

/// Menu-bar (tray) presence: a bell icon that badges itself when there's
/// unread activity (same keys the sidebar badges use — tracker activity
/// keys minus the read set). Clicking it activates and highlights the app.
///
/// The NSStatusItem lives exactly as long as this controller, which lives
/// as long as the RootView — so the icon exists for the whole app session
/// and disappears the moment the app quits (AppKit also tears status items
/// down at process exit).
@MainActor
final class TrayIconController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store: TodoStore
    private let tracker: ActivityTracker
    private var cancellables: Set<AnyCancellable> = []

    init(store: TodoStore, tracker: ActivityTracker) {
        self.store = store
        self.tracker = tracker
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
        }
        update()
        // objectWillChange fires BEFORE @Published values change, so
        // recompute on the next runloop turn to see the new values.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        tracker.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        Diag.log.info("tray icon installed")
    }

    /// Total unread activity across all accounts: raw activity keys per
    /// account minus the read set. Pure — unit-tested without AppKit.
    nonisolated static func unreadCount(jira: [Int64: Set<String>], github: [Int64: Set<String>], read: Set<String>) -> Int {
        var count = 0
        for keys in jira.values { count += keys.subtracting(read).count }
        for keys in github.values { count += keys.subtracting(read).count }
        return count
    }

    private var unreadCount: Int {
        Self.unreadCount(
            jira: tracker.jiraActivityKeys,
            github: tracker.githubActivityKeys,
            read: store.readIssueKeys
        )
    }

    private func update() {
        let unread = unreadCount
        let symbol = unread > 0 ? "bell.badge.fill" : "bell"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: unread > 0 ? "Unread activity" : "No unread activity"
        )
        statusItem.button?.toolTip = unread > 0
            ? "Todo — \(unread) unread"
            : "Todo — all caught up"
    }

    /// Clicking the tray icon just opens/highlights the app window.
    @objc private func clicked() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}