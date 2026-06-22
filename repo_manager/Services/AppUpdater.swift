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

    /// Locates the source repo root.
    ///
    /// Primary source is `SourceRoot.txt`, which the "Embed Source Root" build
    /// phase writes into the bundle with `$SRCROOT` at build time — so this
    /// works whether the app was built from Xcode or run.sh, regardless of where
    /// DerivedData lives. Falls back to walking up from the bundle (the run.sh
    /// layout: `<repo>/DerivedData/Build/Products/Debug/repo_manager.app`).
    static func repoRoot() -> URL? {
        if let baked = bakedSourceRoot(), isRepo(baked) {
            return baked
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return isRepo(url) ? url : nil
    }

    /// Reads the source path baked in by the "Embed Source Root" build phase.
    private static func bakedSourceRoot() -> URL? {
        guard let fileURL = Bundle.main.url(forResource: "SourceRoot", withExtension: "txt"),
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A directory is the source repo if it has both `run.sh` and `.git`.
    private static func isRepo(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.appendingPathComponent("run.sh").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
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
