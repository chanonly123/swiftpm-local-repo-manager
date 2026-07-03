# SwiftPM Git Repo Manager

A native macOS app for managing multiple git repositories from a single interface.

## Video Tutorial

[![](https://markdown-videos-api.jorgenkh.no/youtube/nKA0XtujNEw)](https://www.youtube.com/watch?v=nKA0XtujNEw)


## Features

- Scan any directory and discover all first-level git repositories
- Multi-tab workspace support
- Multi-select repos with batch git operations (fetch, pull, recheckout, hard reset)
- Live status updates via file system monitoring
- Xcode project integration (add local dependencies, toggle run scripts)
- Configurable concurrent operation limit

## Requirements

- macOS 14.0+
- Xcode 15.0+ (for building)
- Git installed on your system

## Installation

Clone the repo and run the launch script — it builds the app and opens it for you:

```sh
git clone https://github.com/chanonly123/swiftpm-local-repo-manager.git
cd swiftpm-local-repo-manager
sh run.sh
```

That's it. `run.sh` builds `repo_manager` with `xcodebuild` and launches the app.

- **Clean build:** `sh run.sh -clean`
- **Xcode instead:** open `repo_manager.xcodeproj` and run with `Cmd+R`.

## Updating

To pull the latest version, rebuild, and relaunch:

```sh
sh update.sh
```

You can also just click **Update App** inside the running app — it runs the same
script in a new Terminal window. `update.sh` always builds from `main`,
auto-stashes any local changes, and restores your branch and changes when it's
done, so it's safe to run even if you're on a feature branch.

## Using the App

1. Click **Select Directory** to choose a folder containing git repos
2. Check the repos you want to operate on
3. Use the bottom bar buttons to run batch git operations
4. Results are shown in a summary sheet after each operation

## License

MIT
