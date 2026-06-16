# Changelog

## Latest Updates (2026-06-11)

### Error Logging
- **Added comprehensive debug logging** for troubleshooting
  - Logs when operations start, succeed, or fail
  - Includes full repository paths in error messages
  - Shows Git-specific error details when available
  - Logs directory scanning progress
  - View logs in Console.app or Xcode debug console

### UI Improvements

#### Select/Deselect All Toggle
- **Added prominent toggle button** in the toolbar (next to directory name)
- Intelligently switches between "Select All" and "Deselect All"
- Visual checkbox indicator that syncs with selection state
- Only shows when repositories are loaded
- Bordered button style for better visibility

#### Compact Row Design
- **40% reduction in row height** for better density
- Repository name and full path on same line (separated by bullet)
- Reduced font sizes for better information density:
  - Name: 13pt semibold
  - Path: 11pt
  - Branch/Status: 11pt
- Tighter spacing throughout (4px → 1-2px)
- Smaller icons and indicators
- More repositories visible on screen at once

### Performance Features
- **Configurable parallel execution** (1, 2, 4, or 8 concurrent operations)
- Default: 4 parallel git operations
- Proper concurrency limiting with automatic queuing
- Results maintain original order

### Enhanced Information Display
- **Full directory paths** shown in:
  - Repository list (inline with name)
  - Operation results popup
- Middle truncation for long paths
- Clear visual separation with bullets

## Architecture

### Files Modified
- `ViewModels/RepoManagerViewModel.swift` - Added logging and concurrency control
- `Views/Components/RepoRowView.swift` - Compact layout redesign
- `ContentView.swift` - Added select/deselect toggle in toolbar

### Logging Categories
- `[DEBUG]` - Informational messages for tracking flow
- `[SUCCESS]` - Successful operations
- `[ERROR]` - Failed operations with details

### Example Log Output
```
[DEBUG] Scanning directory: /Users/username/Code
[DEBUG] Found 15 git repositories
[DEBUG] Starting Pull on: my-repo at /Users/username/Code/my-repo
[SUCCESS] Pull completed for: my-repo
[ERROR] Pull failed for: broken-repo
[ERROR] Path: /Users/username/Code/broken-repo
[ERROR] Message: fatal: not a git repository
```

## Usage Tips

### Debugging Issues
1. Run app from Xcode to see live logs
2. Or open Console.app and filter for "repo_manager"
3. Look for `[ERROR]` tags to identify problems
4. Full paths help identify exact problematic repositories

### Efficient Workflow
1. Click "Select All" toggle in toolbar for bulk operations
2. Adjust parallel execution (1-8) based on your needs:
   - 1: Serial execution, good for debugging
   - 4: Default, balanced performance
   - 8: Maximum speed for many repos
3. Use compact view to see more repositories at once

### Visual Indicators
- ✅ Green circle = Clean working directory
- 🟠 Orange circle = Uncommitted changes
- 🔴 Red circle = Error state
- 🟤 Gray circle = Loading status
