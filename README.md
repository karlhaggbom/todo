# Todo

A minimalistic **native macOS task manager** — local kanban boards plus
first-class Jira Cloud and GitHub integration, all in one app. SwiftUI,
zero external dependencies, SQLite for storage, Vimium-style keyboard
navigation.

Built with the Swift toolchain + Swift Package Manager only — no Xcode
project required.

## What it brings to the table

- **Kanban with drag-and-drop physics** — cards between lanes apply a
  speed-based distortion effect (shear + rotation + squash driven by
  smoothed drag velocity) on *every* board: local, Jira, and GitHub.
  Everything else is instant; it's the only animation in the app.
- **Vimium-style keyboard navigation** — a full cursor-driven keyboard
  engine (`hjkl`/`JKL`/`gg`/`G`, `1`–`9`, `/`, `n`, `dd`, `e`, `Enter`)
  over every board, one keystroke at a time, with an in-app `?` overlay.
- **Jira Cloud, natively** — accounts, spaces (project + JQL, pinned
  boards), status-based lanes, transitions, comments with `@mentions`
  (ADF), attachments, issue creation + editing, deletes with
  confirmation.
- **GitHub, natively** — accounts, repos, open/completed lanes, state
  transitions, `@mentions`, issue creation + editing; pull requests are
  badged purple in the activity feed.
- **A unified multi-source Activity feed** — mentions, assignments,
  comments, and changes on your Jira and GitHub tickets, with
  per-activity read tracking (new activity on a read issue resurfaces as
  unread), "Mark all as read", and a menu-bar **tray icon with an
  unread badge**.
- **Cache-then-network everywhere** — boards and the activity feed
  render instantly from SQLite snapshots, then refresh in the
  background; a background poll keeps badges current every 5 minutes
  without you touching the app. Jira activity polls use **delta
  refreshes** (only issues updated since the last poll) — cheap, polite,
  and fast — with hourly full refreshes to catch removals.
- **GitHub activity via a single GraphQL request** — all repos' mention/
  assigned/review-requested searches are aliased into one query, paid
  from the GraphQL budget instead of the REST search API's hard
  30-requests/minute cap (with an automatic REST fallback).
- **Optimistic everything** — comment add/edit/delete and lane moves
  apply instantly and revert on failure; HTTP status is the only truth.
- **Durable, minimal local state** — SQLite (WAL) at
  `~/Library/Application Support/Todo/todo.sqlite3`; credentials only in
  the macOS Keychain. No Electron, no browser, no background daemons —
  one small app process.

## Build & run

```sh
swift build                 # debug build
swift test                  # run the test suite (Swift Testing)
./build.sh                  # release-build + bundle Todo.app (signed
                            #  with the local "Todo Dev" cert if present)
open Todo.app
```

## Layout

- `Sources/Todo` — the app library:
  - `SQLite.swift` — thin hand-rolled SQLite3 C-API wrapper
  - `Models.swift` / `TodoStore.swift` — lanes, tasks, accounts/spaces/
    repos, read-state, board cache, migrations
  - `AppModel.swift` — keyboard engine + shared cursor/UI state
  - `AppPreferences.swift` — persisted UI toggles (per-board "My
    tickets only", "Show read", activity full-refresh bookkeeping)
  - `KeychainStore.swift` — Jira tokens + GitHub PATs (never in SQLite)
  - `JiraClient.swift` / `JiraModels.swift` — Jira Cloud REST v3 client
    (search, transitions, comments with @mentions via ADF, attachments,
    issue CRUD, changelog) and board + activity models
  - `GitHubClient.swift` / `GitHubModels.swift` — GitHub REST + GraphQL
    client (issues, comments, state changes, aliased activity search)
    and board + activity models
  - `Activity.swift` / `ActivityTracker.swift` — shared activity types,
    per-activity read keys, and the 5-minute background poll
  - `TrayIcon.swift` — menu-bar tray icon with unread badge
  - `Views/` — board, lanes, cards, drag distortion, detail sheets,
    activity feed, Jira/GitHub UI, root window
- `Sources/TodoApp` — executable entry point
- `Tests/TodoTests` — SQLite, store, ADF, keyboard, activity, GraphQL,
  and preferences tests (82 tests)

## Keyboard (local board)

| Key | Action |
|-----|--------|
| `j` / `k` | move cursor down / up |
| `h` / `l` | move cursor between lanes |
| `J` / `K` | move task down / up within lane |
| `H` / `L` | move task to previous / next lane |
| `G` | jump to last task, `gg` to first |
| `n` | quick-add task in current lane (`N` new lane) |
| `e` | rename task |
| `Enter` | open task detail |
| `dd` | delete task |
| `1`–`9` | jump to lane |
| `/` | filter |
| `?` | help overlay |
| `Esc` | cancel input / close overlay |

## Jira & GitHub

Add a Jira account (email + API token) or a GitHub account (PAT) —
credentials live in the macOS Keychain. Then:

- **Jira spaces** (project key + optional JQL) and **GitHub repos**
  become boards; pin your favorites. Statuses/labels form the lanes,
  transitions move cards, `n` creates issues, `e` edits them, `dd`
  deletes with confirmation.
- **Activity** pages per account show everything that needs you:
  mentions, assignments, others' comments and changes, review requests
  (GitHub), newest first, with per-activity read tracking, "Show read",
  and "Mark all as read". Single-click opens the issue detail.
- A **background poll** (every 5 minutes) keeps sidebar unread badges
  and the tray icon current while the app is open.