# Git Repo Manager — macOS SwiftUI App

Manage multiple git repos from a selected directory. Multi-tab workspaces, batch git operations, live FSEvents status, and Xcode project integration.

## Architecture (MVVM)

- **`ContentView.swift`** — root view + tab bar, per-tab `TabContentView`
- **`ViewModels/TabsManager.swift`** — `@Observable`, manages tabs + persistence
- **`ViewModels/RepoManagerViewModel.swift`** — per-tab `@Observable` business logic
- **`Services/GitService.swift`** — `actor`, all git commands via `Process()`
- **`Services/FriscoService.swift`** — `RepoService` actor + `XcodeProjModifier`
- **`Services/FSEventsMonitor.swift`** — live status updates

Layout: `Models/`, `ViewModels/`, `Views/` (+ `Views/Components/`, `Views/Screens/`), `Services/`, `Resources/`.

## Conventions

- **State**: `@State` (view-local only), `@Observable` ViewModels (not `@StateObject`/`@ObservedObject`), `@Bindable` in children, `@Environment` for app-wide config.
- **One type per file**, named after the type. Split any file past ~200 lines into small, focused components placed by role (`Models/`, `Views/Components/`, …).
- **Names**: descriptive (`selectedRepositories`, not `repos`). `struct` for models, `class` only for reference semantics, `enum` for operations/status/errors. `guard let` over nested `if let`; `let` for immutables.
- **Concurrency** (Swift 6 strict): services are `actor`s; mutate ViewModels on `@MainActor` (`await MainActor.run` from concurrent tasks). Batch ops use `withTaskGroup` with `maxConcurrentOperations`; the `isStopping` flag drains queued work without killing in-flight processes.
- **Performance**: `LazyVStack` in `ScrollView`; progressive scan (show repos as `.loading`, fill in branch/status); debounce FSEvents.

## Git operations

- Run via `Process`, executable `/Library/Developer/CommandLineTools/usr/bin/git` (avoids xcrun sandbox issues). Capture stdout + stderr; **drain pipes while the process runs** (reading after exit deadlocks on output > ~64KB). Throw `GitServiceError.commandFailed` on non-zero exit.
- Never pass user-provided strings as shell arguments.
- Per-repo errors don't abort a batch — collect results, continue, show `OperationResultsView`. Confirm destructive ops (hard reset, force push) with an alert.
- Implemented: `fetch`, `pull`, `recheckout` (stash → fetch → `checkout -B` → stash pop), `hardReset`, `status`, `branch`.

## Other notes

- **FSEvents**: on change, identify the repo, skip if in `operatingRepoIDs` (prevents loops), refresh `GitRepo` on `@MainActor`.
- **Persistence**: `TabsManager` saves `[WorkspaceTab]` to `UserDefaults`; restore via security-scoped bookmarks (`.withSecurityScope`, `startAccessingSecurityScopedResource()` / stop in `deinit`).
- **Entitlements**: `files.user-selected.read-write`, `network.client`. Directory selection via `NSOpenPanel`.
- macOS-only — use platform APIs freely (`NSOpenPanel`, FSEvents, `Process`, `NSWorkspace`).
- Preserve existing patterns; don't add abstractions without a clear need. Log git steps with `[DEBUG]`/`[SUCCESS]`/`[ERROR]` prefixes.
- No test cases required.
