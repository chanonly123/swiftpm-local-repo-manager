# Git Repo Manager - SwiftUI Application

## Project Overview

A macOS SwiftUI application for managing multiple git repositories from a selected input directory. Supports multi-tab workspaces, batch git operations, live file-system monitoring, and Xcode project integration.

## Architecture

### Core Components

- **App Entry**: `repo_managerApp.swift`
- **Main View**: `ContentView.swift` — hosts the tab bar and per-tab `TabContentView`
- **Tab Management**: `ViewModels/TabsManager.swift` — `@Observable` class managing tabs and their ViewModels
- **Repo Logic**: `ViewModels/RepoManagerViewModel.swift` — per-tab `@Observable` ViewModel
- **Git Operations**: `Services/GitService.swift` — `actor` for all git commands
- **Xcode Integration**: `Services/FriscoService.swift` — `RepoService` actor + `XcodeProjModifier`
- **File Monitoring**: `Services/FSEventsMonitor.swift` — FSEvents-based live status updates

### Design Patterns

- **MVVM**: `@Observable` classes for ViewModels, plain Swift structs for models
- **Actor isolation**: `GitService` and `RepoService` are `actor` types — all git/file I/O is isolated
- **Structured concurrency**: `withTaskGroup` with a configurable concurrency limit for batch ops
- **Cancellation**: `isStopping` flag allows the Stop button to drain queued operations without killing in-flight processes

## File Organization

```
repo_manager/
├── Models/
│   ├── GitRepo.swift           # Repository data model
│   ├── OperationResult.swift   # Result of a single git operation
│   ├── WorkspaceTab.swift      # Codable tab state (persisted in UserDefaults)
│   └── XcodeProject.swift      # Xcode project descriptor
├── ViewModels/
│   ├── RepoManagerViewModel.swift  # Per-tab business logic
│   └── TabsManager.swift           # Tab lifecycle and persistence
├── Views/
│   ├── ContentView.swift           # Root view + TabContentView
│   └── Components/
│       ├── RepoRowView.swift
│       ├── OperationResultsView.swift
│       └── TabBarView.swift
├── Services/
│   ├── GitService.swift        # Git commands via Process()
│   ├── FriscoService.swift     # RepoService + XcodeProjModifier
│   └── FSEventsMonitor.swift   # File system change monitoring
└── Resources/                  # Assets, entitlements
```

## Code Style Guidelines

### SwiftUI Best Practices

1. **State Management**
   - `@State` for view-local state only
   - `@Observable` macro for ViewModels (not `@StateObject`/`@ObservedObject`)
   - `@Bindable` to bind to `@Observable` objects in child views
   - `@Environment` for app-wide configuration

2. **View Composition**
   - Keep views under 200 lines; extract to separate files
   - Use `extension` blocks (e.g., `extension TabContentView`) to group related computed views
   - Name views descriptively: `RepoRowView`, `TabBarView`, `OperationResultsView`

3. **Performance**
   - `LazyVStack` inside `ScrollView` for the repo list
   - Async scanning with progressive updates — show repos immediately as `.loading`, then update each row with branch/status info
   - Debounce FSEvents callbacks to avoid thrashing on rapid file changes

### Swift Conventions

- Clear, descriptive names: `selectedRepositories` not `repos`
- `struct` for models, `class` only when reference semantics needed
- `enum` for operation types, status, and error cases
- `guard let` for early returns over nested `if let`
- Trailing closures for single closure parameters
- Mark immutable properties `let`

## Git Operations

### Shell Command Execution

```swift
// Pattern used in GitService
let process = Process()
process.executableURL = URL(fileURLWithPath: gitPath)
process.arguments = args
process.currentDirectoryURL = repoURL
let outputPipe = Pipe()
let errorPipe = Pipe()
process.standardOutput = outputPipe
process.standardError = errorPipe
try process.run()
process.waitUntilExit()
```

- Always use `/Library/Developer/CommandLineTools/usr/bin/git` first (avoids xcrun sandbox issues)
- Capture both stdout and stderr
- Throw `GitServiceError.commandFailed` on non-zero exit

### Implemented Operations

| Operation | Description |
|-----------|-------------|
| `fetch` | `git fetch --all` |
| `pull` | `git pull` |
| `recheckout` | stash → fetch → `checkout -B origin/<branch>` → stash pop |
| `hardReset` | `git reset --hard HEAD` + `git clean -f -d` |
| `status` | `git status --porcelain` |
| `branch` | `git branch --show-current` |

### Batch Operation Pattern

Operations run through `performOperation(on:operation:action:)`:
1. Reset `isStopping = false`
2. Start up to `maxConcurrentOperations` tasks in a `TaskGroup`
3. As each finishes, start the next — unless `isStopping` is true
4. Collect ordered results; show `OperationResultsView` when done (skipped if stopped)

### Error Handling

- `GitServiceError` enum with `LocalizedError` conformance
- Per-repo errors don't abort the batch — collect results and continue
- Network failures for remote ops are shown per-repo in the results sheet
- Confirm destructive ops (hard reset) with an alert before executing

## File System Monitoring

`FSEventsMonitor` watches all scanned repo directories. On change:
1. Identify which repo changed
2. Skip if that repo is already in `operatingRepoIDs` (prevents loops during operations)
3. Fetch updated `GitRepo` info and update the list on `@MainActor`

## Xcode Integration

`RepoService` (in `FriscoService.swift`) provides:
- `findXcodeProjects(in:)` — recursively finds `.xcodeproj` bundles, skipping `DerivedData`/`.build`
- `addLocalDependencies(project:baseDirectory:repositories:)` — adds `Package.swift` repos as file references to the Xcode project's main group via `XcodeProjModifier`
- `toggleRunScripts(project:)` — toggles `shellPath` between `/bin/sh` and `/usr/bin/true` to enable/disable build phase run scripts

## Tab Persistence

`TabsManager` persists `[WorkspaceTab]` (Codable) to `UserDefaults`. On restore:
- Security-scoped bookmarks are used to re-access previously selected directories
- Each tab gets a fresh `RepoManagerViewModel`; directory is loaded from the bookmark

## Security & Permissions

### Entitlements Required

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

- Use `NSOpenPanel` for directory selection (provides security-scoped URL)
- Call `url.startAccessingSecurityScopedResource()` before use; `stopAccessingSecurityScopedResource()` in `deinit`
- Create bookmarks with `.withSecurityScope` option for persistence across launches
- Never pass user-provided strings as shell arguments

## Async/Await Patterns

```swift
// Structured concurrency for batch ops
await withTaskGroup(of: (Int, OperationResult).self) { group in
    for repo in selectedRepos {
        group.addTask { await executeOperation(repo) }
    }
    for await result in group {
        results.append(result)
    }
}

// MainActor update from concurrent context
await MainActor.run {
    self.repositories[index] = updatedRepo
}

// Background work started from view
Task {
    await viewModel.recheckoutCurrentBranch()
}
```

## Common Operations

### Adding a New Git Operation

1. Add the command to `GitService` as a new `async throws -> String` method
2. Add the operation case to `OperationResult.GitOperation`
3. Add a public caller in `RepoManagerViewModel` that calls `performOperation`
4. Add a button in `ContentView` (bottom bar or toolbar)

### Adding a New View

1. Create file under `Views/Components/` or `Views/Screens/`
2. Observe `RepoManagerViewModel` via `@Bindable var viewModel`
3. Keep under 200 lines; extract sub-views as private computed vars

## Development Workflow

1. Create/update models in `Models/`
2. Add git/file logic to the appropriate service (`GitService` or `RepoService`)
3. Update `RepoManagerViewModel` with new state and `@MainActor` methods
4. Create/update views in `Views/`
5. Handle errors at each layer with user-friendly messages
6. No test cases required per project requirements

## Notes

- macOS-only — use macOS-specific APIs freely (`NSOpenPanel`, FSEvents, `Process`, `NSWorkspace`)
- Swift 6 strict concurrency — prefer `@MainActor` for ViewModel mutations; use `await MainActor.run` when updating from concurrent tasks
- Preserve existing patterns when adding features; don't introduce new abstractions without a clear need
- Focus on debuggability — git operations are sequential steps; log each one with `[DEBUG]`/`[SUCCESS]`/`[ERROR]` prefixes
