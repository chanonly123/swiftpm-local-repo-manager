# Git Repo Manager

A native macOS app for managing multiple git repositories from a single interface.

## Video Tutorial

> 📹 **Video tutorial coming soon** — placeholder for walkthrough video

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

## Installation & Usage

1. Clone the repository:
   ```sh
   git clone https://github.com/chanonly123/swiftpm-local-repo-manager.git
   cd swiftpm-local-repo-manager
   ```
2. Build and launch the app:
   ```sh
   sh run.sh
   ```
   > Alternatively, open `repo_manager.xcodeproj` in Xcode and run with `Cmd+R`.

## Using the App

1. Click **Select Directory** to choose a folder containing git repos
2. Check the repos you want to operate on
3. Use the bottom bar buttons to run batch git operations
4. Results are shown in a summary sheet after each operation

## License

MIT
