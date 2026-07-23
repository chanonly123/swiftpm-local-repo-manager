import AppKit

/// A third-party Git GUI app (GitHub Desktop / SourceTree) that can open a repo folder.
enum GitDesktopClient: String, CaseIterable, Identifiable {
    case gitHubDesktop
    case sourceTree

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gitHubDesktop: return "GitHub Desktop"
        case .sourceTree: return "SourceTree"
        }
    }

    var systemImage: String {
        switch self {
        case .gitHubDesktop: return "arrow.left.arrow.right"
        case .sourceTree: return "tree"
        }
    }

    /// Bundle identifiers to probe. SourceTree ships under two IDs (MAS vs. direct).
    private var bundleIdentifiers: [String] {
        switch self {
        case .gitHubDesktop: return ["com.github.GitHubClient"]
        case .sourceTree: return ["com.torusknot.SourceTreeNotMAS", "com.torusknot.SourceTree"]
        }
    }

    /// Well-known install locations, checked when LaunchServices lookup fails
    /// (e.g. a sandboxed process, or a Homebrew Cask install not yet registered).
    private var knownPaths: [String] {
        switch self {
        case .gitHubDesktop:
            return ["/Applications/GitHub Desktop.app"]
        case .sourceTree:
            // Homebrew Cask installs it as "Sourcetree.app" (lowercase t).
            return ["/Applications/Sourcetree.app", "/Applications/SourceTree.app"]
        }
    }

    /// The installed app's URL, or `nil` if it isn't installed.
    var applicationURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        for path in knownPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last resort: ask Spotlight, which finds the app in any folder even when
        // LaunchServices won't resolve it for this (sandboxed) process.
        for identifier in bundleIdentifiers {
            if let url = Self.spotlightURL(forBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    /// Cached Spotlight lookups — apps rarely move, so probe each bundle id at most
    /// once per launch (spawning `mdfind` on every view render would be wasteful).
    /// Negative results are cached too, so a missing app isn't re-queried.
    private static var spotlightCache: [String: URL?] = [:]

    private static func spotlightURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        if let cached = spotlightCache[bundleIdentifier] { return cached }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // bundleIdentifier is a compile-time constant (never user input), so this
        // argv value is safe to interpolate into the Spotlight query.
        process.arguments = ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        var result: URL?
        do {
            try process.run()
            // Drain before waiting so a large result set can't deadlock the pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8),
               let firstPath = output.split(separator: "\n").first.map(String.init),
               FileManager.default.fileExists(atPath: firstPath) {
                result = URL(fileURLWithPath: firstPath)
            }
        } catch {
        }

        spotlightCache[bundleIdentifier] = result
        return result
    }

    var isInstalled: Bool { applicationURL != nil }

    /// All clients currently installed on this machine.
    static var installed: [GitDesktopClient] { allCases.filter(\.isInstalled) }

    // MARK: - Preferred client (persisted)

    private static let preferredClientKey = "preferredGitDesktopClient"

    /// The client the user last opened a repo with, persisted across launches.
    static var preferred: GitDesktopClient? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: preferredClientKey) else { return nil }
            return GitDesktopClient(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: preferredClientKey) }
    }

    /// The client to use for a default (double-click) open: the last one the user
    /// picked if it's still installed, otherwise the first installed client.
    static var `default`: GitDesktopClient? {
        if let preferred, preferred.isInstalled { return preferred }
        return installed.first
    }

    /// Opens `repoURL` in this client and remembers it as the preferred client.
    /// Returns `false` if the app isn't installed.
    @discardableResult
    func open(repoURL: URL) -> Bool {
        guard let appURL = applicationURL else {
            return false
        }
        Self.preferred = self
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([repoURL], withApplicationAt: appURL, configuration: config)
        return true
    }
}
