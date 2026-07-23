import Foundation

// Remembers recently applied diff/patch files per repo (most-recent-first, capped at 5), so the
// "Apply Diff/Patch" alert can offer them again without re-prompting the file picker every time.
// Stored as plain file paths in UserDefaults.
enum RecentPatchFileStore {
    private static let maxRecent = 5

    private static func key(for repoURL: URL) -> String {
        "recentPatchFiles.\(repoURL.path)"
    }

    // Most-recent-first list of patch file paths previously applied to this repo.
    static func recentPaths(for repoURL: URL) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: repoURL)) ?? []
    }

    static func recent(for repoURL: URL) -> URL? {
        recentPaths(for: repoURL).first.map { URL(fileURLWithPath: $0) }
    }

    static func save(_ fileURL: URL, for repoURL: URL) {
        var paths = recentPaths(for: repoURL)
        paths.removeAll { $0 == fileURL.path }
        paths.insert(fileURL.path, at: 0)
        if paths.count > maxRecent {
            paths.removeLast(paths.count - maxRecent)
        }
        UserDefaults.standard.set(paths, forKey: key(for: repoURL))
    }
}
