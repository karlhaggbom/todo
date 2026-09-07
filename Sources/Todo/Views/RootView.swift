import SwiftUI
import AppKit

// MARK: - Root

public struct RootView: View {
    @EnvironmentObject var store: TodoStore
    @EnvironmentObject var model: AppModel

    @State private var monitor: Any?
    /// Left-click monitor: a click on the main window behind an open sheet
    /// dismisses the sheet (background-click dismissal).
    @State private var mouseMonitor: Any?
    @State private var showAddAccount = false
    @State private var addSpaceAccount: JiraAccount?
    @State private var showAddGitHubAccount = false
    @State private var addRepoAccount: GitHubAccount?
    @State private var newLaneName = ""
    /// Cached Jira API tokens, keyed by account id. Refreshed when the
    /// account list changes so the keychain is never read synchronously
    /// inside `body` (a keychain read is an XPC round-trip and does not
    /// belong in the SwiftUI render path).
    @State private var jiraTokens: [Int64: String] = [:]
    /// Cached GitHub PATs, same policy as jiraTokens.
    @State private var githubTokens: [Int64: String] = [:]
    /// Explicit expansion state for sidebar account groups. The List's
    /// internal DisclosureGroup bookkeeping collides across sections when
    /// row ids overlap (Jira account 1 vs GitHub account 1), which made
    /// expanding one account collapse the other. Owning the state here
    /// removes the List's buggy machinery from the equation.
    @State private var expandedJiraAccounts: Set<Int64> = []
    @State private var expandedGitHubAccounts: Set<Int64> = []

    // Local board keyboard adapter.
    @State private var localBoard: LocalBoardModel?
    /// Background activity polling (5 min) for the sidebar unread badges.
    @StateObject private var activityTracker = ActivityTracker()
    /// Tray icon — retained here for the whole session; deallocation (or
    /// app quit) removes it from the menu bar.
    @State private var tray: TrayIconController?

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Todo")
        .frame(minWidth: 880, minHeight: 520)
        .onAppear {
            if localBoard == nil {
                let board = LocalBoardModel(store: store, model: model)
                localBoard = board
                model.navigable = { [weak board] in board }
            }
            installKeyMonitor()
            installMouseMonitor()
            if tray == nil {
                tray = TrayIconController(store: store, tracker: activityTracker)
            }
            // The window exists by the first runloop turn after appear.
            DispatchQueue.main.async {
                if model.mainWindow == nil {
                    model.mainWindow = NSApp.keyWindow
                }
            }
            Diag.startProbe()
            Diag.observeMoves()
            Diag.log.info("RootView appeared, spaces=\(store.jiraSpaces.count)")
            if FileManager.default.fileExists(atPath: "/tmp/todo-selftest") ||
                ProcessInfo.processInfo.environment["TODO_SELFTEST"] == "1" {
                Task { @MainActor in
                    Diag.selfCapture()   // t=0: does the local board render at all?
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    Diag.selfCapture()   // still before selecting the board
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    Diag.log.info("SELFTEST: selecting first Jira space")
                    if let space = store.jiraSpaces.first {
                        model.selectedSidebarSection = .jiraSpace(space.id)
                    } else {
                        Diag.log.info("SELFTEST: no Jira spaces in store")
                    }
                    // Health probe runs every 2s; dump the AppKit tree after
                    // the board should have rendered (or died trying).
                    for tick in 1...12 {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        Diag.log.info("SELFTEST tick \(tick) section=\(String(describing: model.selectedSidebarSection))")
                        Diag.selfCapture()
                        if tick % 4 == 0 { Diag.deepDump(); Diag.selfRender() }
                    }
                    Diag.log.info("SELFTEST: finished observing")
                }
            }
        }
        .onDisappear {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet()
        }
        .sheet(item: $addSpaceAccount) { account in
            AddSpaceSheet(account: account)
        }
        .sheet(isPresented: $showAddGitHubAccount) {
            AddGitHubAccountSheet()
        }
        .sheet(item: $addRepoAccount) { account in
            AddGitHubRepoSheet(account: account)
        }
        // Presented from the RootView (not from inside the split view's
        // detail content): sheets presented from the detail area of a
        // NavigationSplitView can corrupt the window's SwiftUI hierarchy on
        // macOS 15, leaving a completely blank window.
        .sheet(item: $model.detailTarget) { target in
            if let content = model.resolveDetail?(target) {
                detailSheet(content)
            }
        }
        .sheet(item: $model.issueDetailTarget) { target in
            detailSheet(target.content, highlight: target.highlight)
                // Activity rows become read when the sheet CLOSES, not when
                // clicked — one visit per row, marked however the sheet
                // ends (Esc, background click, edit handoff, …).
                .onDisappear {
                    if let key = target.readKey { store.markIssueRead(key) }
                }
        }
        .sheet(item: $model.createTarget) { target in
            switch target.content {
            case .jiraIssue(let account, let board):
                CreateIssueSheet(account: account, board: board)
            case .githubIssue(let account, let board):
                CreateGitHubIssueSheet(account: account, board: board)
            }
        }
        .sheet(item: $model.editTarget) { target in
            switch target.content {
            case .jiraIssue(let account, let board, let issue):
                CreateIssueSheet(account: account, board: board, editing: issue)
            case .githubIssue(let account, let board, let issue):
                CreateGitHubIssueSheet(account: account, board: board, editing: issue)
            }
        }
        .sheet(item: $model.deleteTarget) { target in
            ConfirmDeleteSheet(target: target)
        }
        .onAppear { reloadJiraTokens(); reloadGitHubTokens() }
        .onReceive(store.$jiraAccounts) { _ in reloadJiraTokens() }
        .onReceive(store.$githubAccounts) { _ in reloadGitHubTokens() }
        // Refresh activity badges at launch, then every 5 minutes. The
        // models' cache logic keeps repeated ticks cheap (< 60s-old
        // snapshots skip the network entirely).
        .task {
            while !Task.isCancelled {
                await activityTracker.tick(
                    store: store, jiraTokens: jiraTokens, githubTokens: githubTokens
                )
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    public init() {}

    @ViewBuilder
    private func detailSheet(_ content: DetailSheetContent, highlight: ActivityHighlight? = nil) -> some View {
        switch content {
        case .localTask(let task):
            TaskDetailView(task: task)
        case .jiraTicket(let account, let board, let issue):
            TicketDetailView(account: account, board: board, issue: issue,
                             highlightCommentAt: highlight?.reason == .comment ? highlight?.at : nil)
        case .githubIssue(let account, let board, let issue):
            GitHubIssueDetailView(account: account, board: board, issue: issue,
                                 highlightCommentAt: highlight?.reason == .comment ? highlight?.at : nil)
        }
    }

    /// Shared board chrome so `/` (filter) and `?` (help) act on whichever
    /// board is selected, instead of only the local one.
    private func boardChrome(_ content: some View, surface: HelpOverlay.Surface) -> some View {
        VStack(spacing: 0) {
            FilterBar()
            content
        }
        .overlay {
            if model.showHelp { HelpOverlay(surface: surface) }
        }
    }

    private func reloadJiraTokens() {
        var tokens: [Int64: String] = [:]
        for account in store.jiraAccounts {
            if let token = store.token(forAccount: account.id) {
                tokens[account.id] = token
            }
        }
        jiraTokens = tokens
    }

    private func reloadGitHubTokens() {
        var tokens: [Int64: String] = [:]
        for account in store.githubAccounts {
            if let token = store.githubToken(forAccount: account.id) {
                tokens[account.id] = token
            }
        }
        githubTokens = tokens
    }

    // MARK: Modal dismissal

    /// Close the top-most open sheet, one press/click = one concern.
    /// Shared by the Esc handler and background-click dismissal so both
    /// always agree on what's "on top". Returns true if something was open.
    @discardableResult
    private func dismissTopModal() -> Bool {
        if model.detailTarget != nil { model.detailTarget = nil; return true }
        if model.issueDetailTarget != nil { model.issueDetailTarget = nil; return true }
        if model.createTarget != nil { model.createTarget = nil; return true }
        if model.editTarget != nil { model.editTarget = nil; return true }
        if model.deleteTarget != nil { model.deleteTarget = nil; return true }
        if showAddAccount { showAddAccount = false; return true }
        if addSpaceAccount != nil { addSpaceAccount = nil; return true }
        if showAddGitHubAccount { showAddGitHubAccount = false; return true }
        if addRepoAccount != nil { addRepoAccount = nil; return true }
        return false
    }

    /// Clicking the main window's background while a sheet is up dismisses
    /// the sheet — mirroring the Esc chain exactly. The sheet (and menus,
    /// popovers) live in their own NSWindows, so comparing event windows
    /// isolates genuine "behind the modal" clicks. The click is swallowed
    /// so it doesn't also act on the board behind the dismissal.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.window === model.mainWindow, dismissTopModal() {
                return nil
            }
            return event
        }
    }

    // MARK: Keyboard monitor

    /// Sidebar boards in jump order for ⌘1-9: Local Board, then each
    /// account's spaces in sidebar order.
    private var boardSections: [SidebarSection] {
        var sections: [SidebarSection] = [.local]
        for account in store.jiraAccounts {
            for space in store.jiraSpaces where space.accountID == account.id {
                sections.append(.jiraSpace(space.id))
            }
        }
        for account in store.githubAccounts {
            for repo in store.githubRepos where repo.accountID == account.id {
                sections.append(.githubSpace(repo.id))
            }
        }
        return sections
    }

    private func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Diag.log.info("KEY \(event.charactersIgnoringModifiers ?? "?", privacy: .public)")
            // Esc closes the open sheet first; board-state clearing only
            // applies when no sheet is up.
            if event.charactersIgnoringModifiers == "\u{1b}",
               !(event.window?.firstResponder is NSTextView),
               dismissTopModal() {
                return nil
            }
            // ⌘1-9 jumps to boards in sidebar order (⌘1 = Local Board).
            if event.modifierFlags.contains(.command),
               !(event.window?.firstResponder is NSTextView),
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let digit = chars.first?.wholeNumberValue, (1...9).contains(digit) {
                let sections = boardSections
                if sections.indices.contains(digit - 1) {
                    model.selectedSidebarSection = sections[digit - 1]
                    return nil
                }
            }
            if model.handleKey(event) {
                return nil
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                return event
            }
            // Any other plain character (e.g. typed into a text field)
            // interrupts pending `dd`/`gg` sequences.
            if let chars = event.charactersIgnoringModifiers,
               !chars.isEmpty, chars != "\u{1b}", chars != "\r", chars != "\n" {
                model.resetPendingSequences()
            }
            return event
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedSidebarSection) {
            Section("Local") {
                Label("Board", systemImage: "square.split.3x1")
                    .tag(SidebarSection.local)
            }

            Section("Jira") {
                ForEach(store.jiraAccounts) { account in
                    accountRows(account)
                }
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Account…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            Section("GitHub") {
                ForEach(store.githubAccounts) { account in
                    gitHubAccountRows(account)
                }
                Button {
                    showAddGitHubAccount = true
                } label: {
                    Label("Add Account…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            Section("Local Board") {
                if model.newLaneFieldVisible {
                    TextField("New lane name", text: $newLaneName, onCommit: {
                        let name = newLaneName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            _ = try? store.addLane(name: name)
                        }
                        newLaneName = ""
                        model.newLaneFieldVisible = false
                    })
                    .textFieldStyle(.roundedBorder)
                }
                ForEach(store.lanes) { lane in
                    HStack {
                        Text(lane.name)
                        Spacer()
                        Text("\(store.laneTasks(lane.id).count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .contextMenu {
                        Button("Delete Lane") {
                            _ = try? store.deleteLane(lane.id)
                            model.clampSelection()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func gitHubAccountRows(_ account: GitHubAccount) -> some View {
        DisclosureGroup(isExpanded: githubExpansion(account.id)) {
            ForEach(store.githubRepos.filter { $0.accountID == account.id }) { repo in
                Label(repo.name, systemImage: "rectangle.stack")
                    .tag(SidebarSection.githubSpace(repo.id))
                    .contextMenu {
                        Button("Remove Repo") {
                            _ = try? store.deleteGitHubRepo(repo.id)
                            if case .githubSpace(repo.id) = model.selectedSidebarSection {
                                model.selectedSidebarSection = .local
                            }
                        }
                    }
            }
            mentionsRow(unread: githubUnreadCount(account.id))
                .tag(SidebarSection.githubActivity(account.id))
            Button {
                addRepoAccount = account
            } label: {
                Label("Add Repo…", systemImage: "plus")
            }
            .buttonStyle(.plain)
        } label: {
            HStack(spacing: 6) {
                Label(account.name, systemImage: "globe")
                // Collapsed with unread activity: red dot so "something
                // happened" is visible without expanding. When expanded,
                // the Activity row badge carries the count instead.
                if !expandedGitHubAccounts.contains(account.id), githubUnreadCount(account.id) > 0 {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
            }
                .contextMenu {
                    Button("Delete Account") {
                        _ = try? store.deleteGitHubAccount(account.id)
                        switch model.selectedSidebarSection {
                        case .githubActivity(account.id):
                            model.selectedSidebarSection = .local
                        case .githubSpace(let repoID):
                            // Reset if the deleted account owns the open board.
                            if !store.githubRepos.contains(where: { $0.id == repoID }) {
                                model.selectedSidebarSection = .local
                            }
                        default:
                            break
                        }
                    }
                }
        }
        .id("github-account-\(account.id)")
    }

    /// Unread activity for a Jira account: raw activity keys minus the
    /// (published) read set, computed at render time so opening a row
    /// updates the badge instantly. 0 hides the badge.
    private func jiraUnreadCount(_ accountID: Int64) -> Int {
        activityTracker.jiraActivityKeys[accountID]?
            .subtracting(store.readIssueKeys).count ?? 0
    }

    private func githubUnreadCount(_ accountID: Int64) -> Int {
        activityTracker.githubActivityKeys[accountID]?
            .subtracting(store.readIssueKeys).count ?? 0
    }

    /// Sidebar "Activity" row with a trailing unread badge. Hand-rolled
    /// instead of `.badge()`: on macOS, badge modifiers inside sidebar
    /// List rows break the row's click-through (the row stops selecting
    /// once a badge is attached), and plain row content does not.
    private func mentionsRow(unread: Int) -> some View {
        HStack(spacing: 6) {
            Label("Activity", systemImage: "bell.badge")
            Spacer(minLength: 0)
            if unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
            }
        }
    }

    private func jiraExpansion(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { expandedJiraAccounts.contains(id) },
            set: { if $0 { expandedJiraAccounts.insert(id) } else { expandedJiraAccounts.remove(id) } }
        )
    }

    private func githubExpansion(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { expandedGitHubAccounts.contains(id) },
            set: { if $0 { expandedGitHubAccounts.insert(id) } else { expandedGitHubAccounts.remove(id) } }
        )
    }

    @ViewBuilder
    private func accountRows(_ account: JiraAccount) -> some View {
        DisclosureGroup(isExpanded: jiraExpansion(account.id)) {
            ForEach(store.jiraSpaces.filter { $0.accountID == account.id }) { space in
                Label(space.name, systemImage: "rectangle.stack")
                    .tag(SidebarSection.jiraSpace(space.id))
            }
            mentionsRow(unread: jiraUnreadCount(account.id))
                .tag(SidebarSection.jiraActivity(account.id))
            Button {
                addSpaceAccount = account
            } label: {
                Label("Add Space…", systemImage: "plus")
            }
            .buttonStyle(.plain)
        } label: {
            HStack(spacing: 6) {
                Label(account.name, systemImage: "globe")
                // Collapsed with unread activity: red dot so "something
                // happened" is visible without expanding. When expanded,
                // the Activity row badge carries the count instead.
                if !expandedJiraAccounts.contains(account.id), jiraUnreadCount(account.id) > 0 {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
            }
        }
        .contextMenu {
            Button("Delete Account") {
                _ = try? store.deleteJiraAccount(account.id)
                if case .jiraActivity(account.id) = model.selectedSidebarSection {
                    model.selectedSidebarSection = .local
                }
            }
        }
        .id("jira-account-\(account.id)")
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSidebarSection {
        case .local:
            boardChrome(localDetail, surface: .local)

        case .jiraSpace(let spaceID):
            if let pair = jiraPair(spaceID: spaceID), let token = jiraTokens[pair.account.id] {
                boardChrome(
                    JiraBoardView(account: pair.account, space: pair.space, token: token, cache: store)
                        .id(spaceID), // recreate when switching spaces
                    surface: .jira
                )
            } else {
                ContentUnavailableView("Space unavailable", systemImage: "questionmark.circle")
            }

        case .jiraActivity(let accountID):
            if let account = store.jiraAccounts.first(where: { $0.id == accountID }),
               let space = store.jiraSpaces.first(where: { $0.accountID == accountID }),
               let token = jiraTokens[accountID] {
                ActivityView(account: account, space: space, token: token, cache: store)
            } else {
                ContentUnavailableView(
                    "No Space",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Add a Space (project) to this account to see activity.")
                )
            }

        case .githubSpace(let repoID):
            if let pair = gitHubPair(repoID: repoID), let token = githubTokens[pair.account.id] {
                boardChrome(
                    GitHubBoardView(account: pair.account, repo: pair.repo, token: token, cache: store)
                        .id(repoID), // recreate when switching repos
                    surface: .github
                )
            } else {
                ContentUnavailableView("Repo unavailable", systemImage: "questionmark.circle")
            }

        case .githubActivity(let accountID):
            if let account = store.githubAccounts.first(where: { $0.id == accountID }),
               let token = githubTokens[accountID] {
                let repos = store.githubRepos.filter { $0.accountID == accountID }
                if repos.isEmpty {
                    ContentUnavailableView(
                        "No Repo",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add a Repo to this account to see activity.")
                    )
                } else {
                    GitHubActivityView(account: account, repos: repos, token: token, cache: store)
                }
            } else {
                ContentUnavailableView("Account unavailable", systemImage: "questionmark.circle")
            }
        }
    }

    @ViewBuilder
    private var localDetail: some View {
        BoardView()
            .id("local")
            .onAppear {
                // Re-assert the local board as the keyboard surface whenever the
                // local board becomes visible again (e.g. after a Jira board).
                if let localBoard { model.navigable = { [weak localBoard] in localBoard } }
            }
    }

    private func jiraPair(spaceID: Int64) -> (account: JiraAccount, space: JiraSpace)? {
        guard let space = store.jiraSpaces.first(where: { $0.id == spaceID }),
              let account = store.jiraAccounts.first(where: { $0.id == space.accountID }) else {
            return nil
        }
        return (account, space)
    }

    private func gitHubPair(repoID: Int64) -> (account: GitHubAccount, repo: GitHubRepo)? {
        guard let repo = store.githubRepos.first(where: { $0.id == repoID }),
              let account = store.githubAccounts.first(where: { $0.id == repo.accountID }) else {
            return nil
        }
        return (account, repo)
    }
}