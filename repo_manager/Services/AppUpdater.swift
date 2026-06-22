import AppKit
import Foundation

/// Self-update for the dev build: pulls the latest source, rebuilds via
/// `run.sh`, and relaunches.
///
/// A running process can't rebuild and replace its own binary, so the actual
/// work is handed off to `update.sh`, which runs detached in a new Terminal
/// window. That script waits for this instance to quit before pulling and
/// building, then relaunches the freshly built app.
enum AppUpdater {
    enum UpdateError: LocalizedError {
        case repoNotFound

        var errorDescription: String? {
            switch self {
            case .repoNotFound:
                return "Couldn't locate the source repository. Self-update only works when the app is built with run.sh (DerivedData lives inside the cloned repo)."
            }
        }
    }

    /// Derives the source repo root from the running app's bundle location.
    ///
    /// `run.sh` builds to `<repo>/DerivedData/Build/Products/Debug/repo_manager.app`,
    /// so the repo root is five directories up from the bundle. We verify by
    /// checking for `run.sh` and `.git`.
    static func repoRoot() -> URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<5 { url.deleteLastPathComponent() }

        let fileManager = FileManager.default
        let runScript = url.appendingPathComponent("run.sh")
        let gitDir = url.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: runScript.path),
              fileManager.fileExists(atPath: gitDir.path) else {
            return nil
        }
        return url
    }

    /// True when this build can self-update (was built via run.sh).
    static var canUpdate: Bool { repoRoot() != nil }

    /// Launches the detached update script in Terminal, then quits the app so
    /// its binary can be replaced.
    @MainActor
    static func updateAndRestart() throws {
        guard let repo = repoRoot() else { throw UpdateError.repoNotFound }
        let script = repo.appendingPathComponent("update.sh")

        // Single-quote the paths for the shell; no double quotes inside, so the
        // command embeds cleanly in the AppleScript string below.
        let shellCommand = "'\(script.path)' '\(repo.path)'"
        let appleScript = """
        tell application "Terminal"
            do script "\(shellCommand)"
            activate
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        try process.run()
        process.waitUntilExit()

        print("[DEBUG] Update handed off to \(script.path); quitting app")
        NSApp.terminate(nil)
    }
}
