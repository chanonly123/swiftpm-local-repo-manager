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

    /// The installed app's URL, or `nil` if it isn't installed.
    var applicationURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    var isInstalled: Bool { applicationURL != nil }

    /// All clients currently installed on this machine.
    static var installed: [GitDesktopClient] { allCases.filter(\.isInstalled) }

    /// Opens `repoURL` in this client. Returns `false` if the app isn't installed.
    @discardableResult
    func open(repoURL: URL) -> Bool {
        guard let appURL = applicationURL else {
            debugLog("[ERROR] \(displayName) is not installed")
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([repoURL], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                debugLog("[ERROR] Failed to open \(self.displayName): \(error)")
            } else {
                debugLog("[SUCCESS] Opened \(repoURL.path) in \(self.displayName)")
            }
        }
        return true
    }
}
