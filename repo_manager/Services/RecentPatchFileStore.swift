import Foundation

// Remembers the most recently applied diff/patch file per repo, so the "Apply Diff/Patch"
// alert can offer it again without re-prompting the file picker every time. Stored as a
// security-scoped bookmark (not a plain path) since the app is sandboxed and needs renewed
// access to the file across launches.
enum RecentPatchFileStore {
    private static func key(for repoURL: URL) -> String {
        "recentPatchFile.\(repoURL.path)"
    }

    static func save(_ fileURL: URL, for repoURL: URL) {
        guard let bookmark = try? fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: key(for: repoURL))
    }

    // Resolves the stored bookmark to a URL, without starting security-scoped access.
    static func recent(for repoURL: URL) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key(for: repoURL)) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }
}
