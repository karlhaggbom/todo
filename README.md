# Todo

A minimalistic native macOS kanban task board. SwiftUI, no external
dependencies, SQLite for storage, Vimium-style keyboard navigation, and
optional Jira Cloud integration.

Built with the Swift toolchain + Swift Package Manager only — no Xcode
project required.

## Build & run

```sh
swift build                 # debug build
swift test                  # run the test suite (Swift Testing)
./build.sh                  # release-build + bundle Todo.app (ad-hoc signed)
open Todo.app
```

## Layout

- `Sources/Todo` — the app library:
  - `SQLite.swift` — thin hand-rolled SQLite3 C-API wrapper
  - `Models.swift` / `TodoStore.swift` — lanes, tasks, Jira account/space records
  - `AppModel.swift` — keyboard engine + shared cursor/UI state
  - `KeychainStore.swift` — Jira API tokens (never stored in SQLite)
  - `JiraClient.swift` — Jira Cloud REST v3 client (search, transitions,
    comments with @mentions via ADF, attachments)
  - `JiraModels.swift` — Jira board + mentions models
  - `Views/` — board, lanes, cards, drag distortion, detail sheets, Jira UI
- `Sources/TodoApp` — executable entry point
- `Tests/TodoTests` — SQLite, store, ADF, and keyboard tests

Data lives at `~/Library/Application Support/todo/todo.sqlite3` (WAL mode).

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

Dragging cards between lanes applies a speed-based distortion effect
(shear + rotation + squash driven by smoothed drag velocity) — the only
animation in the app; keyboard navigation is instant.

## Jira

Add an account (email + API token; the token is stored in the Keychain),
add spaces (project key + optional JQL), then browse issues in
status-based lanes, apply transitions, comment with `@mentions`, and
attach files. A "Mentions" view lists issues that mention you.# todo
